unless Code.ensure_loaded?(ElixirClaw.MockDiscordAPI) do
  Mox.defmock(ElixirClaw.MockDiscordAPI, for: ElixirClaw.Channels.Discord.API)
end

unless Code.ensure_loaded?(ElixirClaw.MockDiscordSessionManager) do
  Mox.defmock(ElixirClaw.MockDiscordSessionManager, for: ElixirClaw.Channels.Discord.SessionManager)
end

unless Code.ensure_loaded?(ElixirClaw.MockDiscordAgentLoop) do
  Mox.defmock(ElixirClaw.MockDiscordAgentLoop, for: ElixirClaw.Channels.Discord.AgentLoop)
end

defmodule ElixirClaw.Channels.DiscordTest do
  use ExUnit.Case, async: false

  import Mox

  alias ElixirClaw.Channels.Discord
  alias ElixirClaw.Types.Message

  setup :verify_on_exit!

  setup do
    Application.put_env(:elixir_claw, :discord_api, ElixirClaw.MockDiscordAPI)
    Application.put_env(:elixir_claw, :discord_session_manager, ElixirClaw.MockDiscordSessionManager)
    Application.put_env(:elixir_claw, :discord_agent_loop, ElixirClaw.MockDiscordAgentLoop)

    :ok
  end

  describe "sanitize_input/1" do
    test "removes prompt injection markers" do
      assert Discord.sanitize_input("hello <|system|> [INST] <<SYS>> world") ==
               "hello system world"
    end
  end

  describe "handle_incoming/1" do
    test "converts a Discord message into an ElixirClaw message" do
      assert {:ok,
              %Message{role: "user", content: "hello system world", timestamp: ~U[2026-03-24 04:00:00Z]}} =
               Discord.handle_incoming(%{
                 content: "hello <|system|> [INST] <<SYS>> world",
                 timestamp: ~U[2026-03-24 04:00:00Z]
               })
    end

    test "returns an error for messages without text content" do
      assert {:error, :unsupported_message} = Discord.handle_incoming(%{content: nil})
    end
  end

  describe "Discord consumer handling" do
    test "ignores bot-authored messages" do
      {:ok, pid} = start_discord(bot_user_id: 999)

      assert :ok = Discord.handle_event({:MESSAGE_CREATE, discord_message("hello", author_bot: true), %{pid: pid}})
      assert_receive {:discord_ignored, :bot_message}
      refute_receive _
    end

    test "ignores messages from the configured bot user id" do
      {:ok, pid} = start_discord(bot_user_id: 123)

      assert :ok = Discord.handle_event({:MESSAGE_CREATE, discord_message("hello", author_id: 123), %{pid: pid}})
      assert_receive {:discord_ignored, :self_message}
      refute_receive _
    end

    test "ignores guild text that is not a command" do
      {:ok, pid} = start_discord()

      assert :ok =
               Discord.handle_event(
                 {:MESSAGE_CREATE, discord_message("hello", guild_id: 456), %{pid: pid}}
               )

      assert_receive {:discord_ignored, :unsupported_message}
    end

    test "responds to !help without invoking the agent loop" do
      expect(ElixirClaw.MockDiscordAPI, :create_message, fn 222, content ->
        assert content =~ "!help"
        assert content =~ "!new"
        {:ok, %{id: 1}}
      end)

      {:ok, pid} = start_discord(channel_id: 222)

      assert :ok = Discord.handle_event({:MESSAGE_CREATE, discord_message("!help", channel_id: 222), %{pid: pid}})
    end

    test "starts a session for the first DM and reuses it for later messages" do
      expect(ElixirClaw.MockDiscordSessionManager, :start_session, fn attrs ->
        assert attrs.channel == "discord"
        assert attrs.channel_user_id == "111:222"
        assert attrs.provider == "openai"
        assert attrs.model == "gpt-5"
        assert attrs.metadata.discord_channel_id == 222
        assert attrs.metadata.discord_user_id == 111
        {:ok, "session-1"}
      end)

      expect(ElixirClaw.MockDiscordAgentLoop, :process_message, fn "session-1", "hello system world" ->
        {:ok, %{}}
      end)

      expect(ElixirClaw.MockDiscordAgentLoop, :process_message, fn "session-1", "follow up" ->
        {:ok, %{}}
      end)

      {:ok, pid} = start_discord(provider: "openai", model: "gpt-5")

      assert :ok =
               Discord.handle_event(
                 {:MESSAGE_CREATE, discord_message("hello <|system|> world"), %{pid: pid}}
               )

      assert :ok = Discord.handle_event({:MESSAGE_CREATE, discord_message("follow up"), %{pid: pid}})

      state = :sys.get_state(pid)
      assert state.session_by_user_channel[{111, 222}] == "session-1"
      assert state.route_by_session["session-1"] == %{channel_id: 222, user_id: 111}
    end

    test "!new replaces the existing session and confirms to the user" do
      expect(ElixirClaw.MockDiscordSessionManager, :start_session, fn _attrs -> {:ok, "session-1"} end)

      expect(ElixirClaw.MockDiscordAgentLoop, :process_message, fn "session-1", "hello" ->
        {:ok, %{}}
      end)

      expect(ElixirClaw.MockDiscordSessionManager, :end_session, fn "session-1" -> :ok end)

      expect(ElixirClaw.MockDiscordSessionManager, :start_session, fn _attrs -> {:ok, "session-2"} end)

      expect(ElixirClaw.MockDiscordAPI, :create_message, fn 222, "Started a new session." ->
        {:ok, %{id: 2}}
      end)

      {:ok, pid} = start_discord()

      assert :ok = Discord.handle_event({:MESSAGE_CREATE, discord_message("hello"), %{pid: pid}})
      assert :ok = Discord.handle_event({:MESSAGE_CREATE, discord_message("!new"), %{pid: pid}})

      state = :sys.get_state(pid)
      assert state.session_by_user_channel[{111, 222}] == "session-2"
    end
  end

  describe "send_message/3" do
    test "splits Discord responses into 2000 character chunks" do
      long_content = String.duplicate("a", 4001)

      expect(ElixirClaw.MockDiscordAPI, :create_message, fn 222, chunk ->
        assert String.length(chunk) == 2000
        {:ok, %{id: 1}}
      end)

      expect(ElixirClaw.MockDiscordAPI, :create_message, fn 222, chunk ->
        assert String.length(chunk) == 2000
        {:ok, %{id: 2}}
      end)

      expect(ElixirClaw.MockDiscordAPI, :create_message, fn 222, "a" ->
        {:ok, %{id: 3}}
      end)

      {:ok, pid} = start_discord()
      :sys.replace_state(pid, fn state ->
        %{state | route_by_session: %{"session-1" => %{channel_id: 222, user_id: 111}}}
      end)

      assert :ok = Discord.send_message(pid, "session-1", long_content)
    end

    test "returns an error when the session is unknown" do
      {:ok, pid} = start_discord()
      assert {:error, :unknown_session} = Discord.send_message(pid, "missing", "hello")
    end
  end

  defp start_discord(opts \\ []) do
    config =
      %{
        provider: "openai",
        model: "gpt-5",
        bot_user_id: nil,
        test_pid: self()
      }
      |> Map.merge(Enum.into(opts, %{}))

    Discord.start_link(config)
  end

  defp discord_message(content, opts \\ []) do
    %{
      content: content,
      channel_id: Keyword.get(opts, :channel_id, 222),
      guild_id: Keyword.get(opts, :guild_id, nil),
      timestamp: Keyword.get(opts, :timestamp, ~U[2026-03-24 04:00:00Z]),
      author: %{
        id: Keyword.get(opts, :author_id, 111),
        bot: Keyword.get(opts, :author_bot, nil)
      }
    }
  end
end
