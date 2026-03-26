defmodule ElixirClaw.Channels.TelegramTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias ElixirClaw.Bus.MessageBus
  alias ElixirClaw.Channels.Telegram
  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.Message, as: MessageSchema
  alias ElixirClaw.Schema.Session, as: SessionSchema
  alias ElixirClaw.Session.Manager
  alias ElixirClaw.Types.Message

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    Mox.set_mox_global()

    Repo.reset!()
    Repo.delete_all(MessageSchema)
    Repo.delete_all(SessionSchema)
    kill_session_processes()

    previous_config = Application.get_env(:elixir_claw, Telegram)

    Application.put_env(:elixir_claw, Telegram,
      bot_token: "123456:test_bot_token",
      telegex_api: ElixirClaw.MockTelegex,
      agent_loop: ElixirClaw.MockTelegramAgentLoop,
      audio_transcriber: ElixirClaw.MockAudioTranscriber,
      provider: "openai",
      model: "gpt-4o-mini",
      start_polling: false,
      test_pid: self()
    )

    on_exit(fn ->
      restore_config(previous_config)
      kill_session_processes()
    end)

    stub(ElixirClaw.MockTelegramAgentLoop, :process_message, fn _session_id, _content ->
      {:ok, %{}}
    end)

    stub(ElixirClaw.MockAudioTranscriber, :transcribe, fn _audio_binary, _opts ->
      {:error, :not_configured}
    end)

    stub(ElixirClaw.MockTelegex, :get_file, fn _file_id ->
      {:ok, %{file_path: "voice/test.ogg"}}
    end)

    stub(ElixirClaw.MockTelegex, :get_me, fn ->
      {:ok, %{username: "claw_test_bot"}}
    end)

    stub(ElixirClaw.MockTelegex, :delete_webhook, fn _opts ->
      {:ok, true}
    end)

    stub(ElixirClaw.MockTelegex, :get_updates, fn _opts ->
      {:ok, []}
    end)

    stub(ElixirClaw.MockTelegex, :set_webhook, fn _opts ->
      {:error, :webhook_disabled}
    end)

    :ok
  end

  describe "start_link/1" do
    test "returns invalid_token for malformed tokens without leaking the token" do
      log =
        capture_log(fn ->
          assert {:error, :invalid_token} = Telegram.start_link(%{bot_token: "not-a-real-token"})
        end)

      refute log =~ "not-a-real-token"
    end

    test "starts with valid config" do
      stub(ElixirClaw.MockTelegex, :send_message, fn _chat_id, _text -> {:ok, %{}} end)
      stub(ElixirClaw.MockTelegex, :get_updates, fn _opts -> {:ok, []} end)
      stub(ElixirClaw.MockTelegex, :delete_webhook, fn _opts -> {:ok, true} end)
      stub(ElixirClaw.MockTelegex, :get_me, fn -> {:ok, %{username: "claw_test_bot"}} end)

      stub(ElixirClaw.MockTelegramAgentLoop, :process_message, fn _session_id, _content ->
        {:ok, %{}}
      end)

      assert {:ok, pid} = start_supervised(Telegram)
      assert Process.alive?(pid)
    end

    test "polls updates on boot and processes /start plus regular messages" do
      parent = self()

      expect(ElixirClaw.MockTelegex, :delete_webhook, fn [drop_pending_updates: false] ->
        send(parent, :telegram_deleted_webhook)
        {:ok, true}
      end)

      expect(ElixirClaw.MockTelegex, :get_me, fn ->
        send(parent, :telegram_get_me)
        {:ok, %{username: "claw_test_bot"}}
      end)

      expect(ElixirClaw.MockTelegex, :get_updates, fn opts ->
        send(parent, {:telegram_polled_opts, opts})

        {:ok,
         [
           Map.put(private_text_update(501, "/start"), :update_id, 10),
           Map.put(private_text_update(501, "hello from polling"), :update_id, 11)
         ]}
      end)

      stub(ElixirClaw.MockTelegex, :send_message, fn chat_id, text ->
        send(parent, {:telegram_sent_message, chat_id, text})
        {:ok, %{message_id: System.unique_integer([:positive])}}
      end)

      expect(ElixirClaw.MockTelegramAgentLoop, :process_message, fn session_id,
                                                                    "hello from polling" ->
        send(parent, {:telegram_agent_loop_called, session_id})
        {:ok, %{}}
      end)

      assert {:ok, pid} =
               Telegram.start_link(
                 bot_token: "123456:test_bot_token",
                 telegex_api: ElixirClaw.MockTelegex,
                 agent_loop: ElixirClaw.MockTelegramAgentLoop,
                 provider: "openai",
                 model: "gpt-4o-mini",
                 start_polling: true,
                 test_pid: parent,
                 poll_interval: 5,
                 poll_timeout: 0
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive :telegram_deleted_webhook
      assert_receive :telegram_get_me

      assert_receive {:telegram_polled_opts, opts}
      assert opts[:offset] == 0
      assert opts[:allowed_updates] == ["message"]

      assert_receive {:telegram_sent_message, 501, welcome_text}
      assert welcome_text =~ "Welcome to ElixirClaw Telegram"

      assert_receive {:telegram_agent_loop_called, session_id}

      state = :sys.get_state(pid)
      assert state.chat_sessions[501] == session_id
      assert state.poll_offset == 12
    end

    test "prefers webhook mode when webhook config is present" do
      parent = self()

      expect(ElixirClaw.MockTelegex, :get_me, fn ->
        send(parent, :telegram_get_me)
        {:ok, %{username: "claw_test_bot"}}
      end)

      expect(ElixirClaw.MockTelegex, :set_webhook, fn opts ->
        send(parent, {:telegram_set_webhook, opts})
        {:ok, true}
      end)

      stub(ElixirClaw.MockTelegex, :delete_webhook, fn _opts ->
        send(parent, :telegram_deleted_webhook_unexpected)
        {:ok, true}
      end)

      stub(ElixirClaw.MockTelegex, :get_updates, fn _opts ->
        send(parent, :telegram_polled_unexpected)
        {:ok, []}
      end)

      assert {:ok, pid} =
               Telegram.start_link(
                 bot_token: "123456:test_bot_token",
                 telegex_api: ElixirClaw.MockTelegex,
                 agent_loop: ElixirClaw.MockTelegramAgentLoop,
                 start_polling: true,
                 webhook_enabled: true,
                 webhook_url: "https://example.com/telegram/webhook",
                 webhook_secret_token: "secret-123",
                 webhook_port: 4100,
                 test_pid: parent
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive :telegram_get_me

      assert_receive {:telegram_webhook_enabled, opts}
      assert opts[:url] == "https://example.com/telegram/webhook"
      assert opts[:secret_token] == "secret-123"
      assert opts[:allowed_updates] == ["message"]

      assert_receive {:telegram_set_webhook, webhook_opts}
      assert webhook_opts[:url] == "https://example.com/telegram/webhook"
      assert webhook_opts[:secret_token] == "secret-123"

      refute_receive :telegram_polled_unexpected, 20
      refute_receive :telegram_deleted_webhook_unexpected, 20

      state = :sys.get_state(pid)
      assert state.transport_mode == :webhook
      refute state.start_polling?
    end

    test "falls back to polling when webhook setup fails" do
      parent = self()

      expect(ElixirClaw.MockTelegex, :get_me, fn ->
        send(parent, :telegram_get_me)
        {:ok, %{username: "claw_test_bot"}}
      end)

      expect(ElixirClaw.MockTelegex, :set_webhook, fn _opts ->
        {:error, :econnrefused}
      end)

      expect(ElixirClaw.MockTelegex, :delete_webhook, fn [drop_pending_updates: false] ->
        send(parent, :telegram_deleted_webhook)
        {:ok, true}
      end)

      expect(ElixirClaw.MockTelegex, :get_updates, fn opts ->
        send(parent, {:telegram_polled_opts, opts})
        {:ok, []}
      end)

      assert {:ok, pid} =
               Telegram.start_link(
                 bot_token: "123456:test_bot_token",
                 telegex_api: ElixirClaw.MockTelegex,
                 agent_loop: ElixirClaw.MockTelegramAgentLoop,
                 start_polling: true,
                 webhook_enabled: true,
                 webhook_url: "https://example.com/telegram/webhook",
                 webhook_secret_token: "secret-123",
                 webhook_port: 4100,
                 test_pid: parent,
                 poll_interval: 5,
                 poll_timeout: 0
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive :telegram_get_me
      assert_receive {:telegram_webhook_fallback, :econnrefused}
      assert_receive :telegram_deleted_webhook
      assert_receive {:telegram_polled_opts, opts}
      assert opts[:allowed_updates] == ["message"]

      state = :sys.get_state(pid)
      assert state.transport_mode == :polling
      assert state.start_polling?
    end

    test "does not log long polling timeouts as warnings" do
      parent = self()
      poll_counter = :erlang.make_ref()

      expect(ElixirClaw.MockTelegex, :delete_webhook, fn [drop_pending_updates: false] ->
        {:ok, true}
      end)

      expect(ElixirClaw.MockTelegex, :get_me, fn ->
        {:ok, %{username: "claw_test_bot"}}
      end)

      stub(ElixirClaw.MockTelegex, :get_updates, fn _opts ->
        count = Process.get(poll_counter, 0)
        Process.put(poll_counter, count + 1)

        if count == 0 do
          send(parent, :telegram_timeout_polled)
          {:error, %Telegex.RequestError{reason: :timeout}}
        else
          Process.sleep(50)
          {:ok, []}
        end
      end)

      log =
        capture_log(fn ->
          assert {:ok, pid} =
                   Telegram.start_link(
                     bot_token: "123456:test_bot_token",
                     telegex_api: ElixirClaw.MockTelegex,
                     agent_loop: ElixirClaw.MockTelegramAgentLoop,
                     start_polling: true,
                     test_pid: self(),
                     poll_interval: 5,
                     poll_timeout: 0
                   )

          assert_receive :telegram_timeout_polled
          Process.sleep(20)

          wait_until(fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 0} end)
          :sys.get_state(pid)

          GenServer.stop(pid)
        end)

      refute log =~ "Telegram polling failed"
    end

    test "uses runtime-configured default provider and model when channel config omits them" do
      stub(ElixirClaw.MockTelegramAgentLoop, :process_message, fn _session_id, _content ->
        {:ok, %{}}
      end)

      previous_channel_config = Application.get_env(:elixir_claw, Telegram)
      previous_default_provider = Application.get_env(:elixir_claw, :default_provider)
      previous_default_model = Application.get_env(:elixir_claw, :default_model)

      Application.put_env(:elixir_claw, Telegram,
        bot_token: "123456:test_bot_token",
        telegex_api: ElixirClaw.MockTelegex,
        agent_loop: ElixirClaw.MockTelegramAgentLoop,
        start_polling: false
      )

      Application.put_env(:elixir_claw, :default_provider, "github_copilot")
      Application.put_env(:elixir_claw, :default_model, "gpt-5.4-mini")

      on_exit(fn ->
        if is_nil(previous_channel_config),
          do: Application.delete_env(:elixir_claw, Telegram),
          else: Application.put_env(:elixir_claw, Telegram, previous_channel_config)

        if is_nil(previous_default_provider),
          do: Application.delete_env(:elixir_claw, :default_provider),
          else: Application.put_env(:elixir_claw, :default_provider, previous_default_provider)

        if is_nil(previous_default_model),
          do: Application.delete_env(:elixir_claw, :default_model),
          else: Application.put_env(:elixir_claw, :default_model, previous_default_model)
      end)

      assert {:ok, pid} =
               Telegram.start_link(
                 bot_token: "123456:test_bot_token",
                 telegex_api: ElixirClaw.MockTelegex,
                 agent_loop: ElixirClaw.MockTelegramAgentLoop,
                 start_polling: false,
                 test_pid: self()
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert {:ok, session_id} = Telegram.process_update(pid, private_text_update(901, "hello"))
      assert {:ok, session} = Manager.get_session(session_id)
      assert session.provider == "github_copilot"
      assert session.model == "gpt-5.4-mini"
    end
  end

  describe "sanitize_input/1" do
    test "strips prompt injection markers" do
      assert Telegram.sanitize_input("hello <| [INST] <<SYS>> world |> ") == "hello world"
    end
  end

  describe "handle_incoming/1" do
    test "parses telegex update maps into sanitized user messages" do
      update = %{
        message: %{
          text: "hello <| [INST] world |>",
          date: 1_717_171_717,
          chat: %{id: 1001, type: "private"}
        }
      }

      assert {:ok, %Message{} = message} = Telegram.handle_incoming(update)
      assert message.role == "user"
      assert message.content == "hello world"
      assert %DateTime{} = message.timestamp
    end

    test "parses photo updates into multimodal user content with caption" do
      bypass = Bypass.open()

      expect(ElixirClaw.MockTelegex, :get_file, fn "photo-large" ->
        {:ok, %{file_path: "photos/test.jpg"}}
      end)

      Bypass.expect_once(
        bypass,
        "GET",
        "/file/bot123456:test_bot_token/photos/test.jpg",
        fn conn ->
          Plug.Conn.resp(conn, 200, "fake-image")
        end
      )

      previous_token = Application.get_env(:telegex, :token)
      previous_req_options = Application.get_env(:elixir_claw, :telegram_req_options)
      Application.put_env(:telegex, :token, "123456:test_bot_token")

      Application.put_env(:elixir_claw, :telegram_req_options,
        base_url: "http://localhost:#{bypass.port}"
      )

      on_exit(fn ->
        if is_nil(previous_token),
          do: Application.delete_env(:telegex, :token),
          else: Application.put_env(:telegex, :token, previous_token)

        if is_nil(previous_req_options),
          do: Application.delete_env(:elixir_claw, :telegram_req_options),
          else: Application.put_env(:elixir_claw, :telegram_req_options, previous_req_options)
      end)

      update = %{
        message: %{
          caption: "look at this <| image |>",
          photo: [
            %{file_id: "photo-small"},
            %{file_id: "photo-large", file_unique_id: "photo-unique"}
          ],
          date: 1_717_171_717,
          chat: %{id: 1003, type: "private"}
        }
      }

      assert {:ok, %Message{} = message} = Telegram.handle_incoming(update)
      assert message.role == "user"

      assert [
               %{type: "image_url", image_url: %{url: data_url, detail: "auto"}},
               %{type: "text", text: "look at this image"}
             ] = message.content

      assert data_url == "data:image/jpeg;base64,ZmFrZS1pbWFnZQ=="
    end

    test "parses photo-only updates into multimodal image content" do
      bypass = Bypass.open()

      expect(ElixirClaw.MockTelegex, :get_file, fn "photo-large" ->
        {:ok, %{file_path: "photos/test.jpg"}}
      end)

      Bypass.expect_once(
        bypass,
        "GET",
        "/file/bot123456:test_bot_token/photos/test.jpg",
        fn conn ->
          Plug.Conn.resp(conn, 200, "fake-image")
        end
      )

      previous_token = Application.get_env(:telegex, :token)
      previous_req_options = Application.get_env(:elixir_claw, :telegram_req_options)
      Application.put_env(:telegex, :token, "123456:test_bot_token")

      Application.put_env(:elixir_claw, :telegram_req_options,
        base_url: "http://localhost:#{bypass.port}"
      )

      on_exit(fn ->
        if is_nil(previous_token),
          do: Application.delete_env(:telegex, :token),
          else: Application.put_env(:telegex, :token, previous_token)

        if is_nil(previous_req_options),
          do: Application.delete_env(:elixir_claw, :telegram_req_options),
          else: Application.put_env(:elixir_claw, :telegram_req_options, previous_req_options)
      end)

      update = %{
        message: %{
          photo: [
            %{file_id: "photo-small"},
            %{file_id: "photo-large", file_unique_id: "photo-unique"}
          ],
          date: 1_717_171_719,
          chat: %{id: 1007, type: "private"}
        }
      }

      assert {:ok, %Message{} = message} = Telegram.handle_incoming(update)
      assert message.role == "user"

      assert [
               %{type: "image_url", image_url: %{url: data_url, detail: "auto"}}
             ] = message.content

      assert data_url == "data:image/jpeg;base64,ZmFrZS1pbWFnZQ=="
    end

    test "parses audio updates into structured text content" do
      bypass = Bypass.open()

      expect(ElixirClaw.MockTelegex, :get_file, fn "audio-1" ->
        {:ok, %{file_path: "audio/test.mp3"}}
      end)

      Bypass.expect_once(
        bypass,
        "GET",
        "/file/bot123456:test_bot_token/audio/test.mp3",
        fn conn ->
          Plug.Conn.resp(conn, 200, "audio-binary")
        end
      )

      expect(ElixirClaw.MockAudioTranscriber, :transcribe, fn "audio-binary", opts ->
        assert opts[:caption] == "daily brief"
        assert opts[:duration] == 12
        assert opts[:performer] == "Claw"
        assert opts[:title] == "Brief"
        assert opts[:filename] == "Brief.mp3"
        assert opts[:content_type] == "audio/mpeg"
        {:ok, "transcribed spoken text"}
      end)

      previous_token = Application.get_env(:telegex, :token)
      previous_req_options = Application.get_env(:elixir_claw, :telegram_req_options)
      Application.put_env(:telegex, :token, "123456:test_bot_token")

      Application.put_env(:elixir_claw, :telegram_req_options,
        base_url: "http://localhost:#{bypass.port}"
      )

      on_exit(fn ->
        if is_nil(previous_token),
          do: Application.delete_env(:telegex, :token),
          else: Application.put_env(:telegex, :token, previous_token)

        if is_nil(previous_req_options),
          do: Application.delete_env(:elixir_claw, :telegram_req_options),
          else: Application.put_env(:elixir_claw, :telegram_req_options, previous_req_options)
      end)

      update = %{
        message: %{
          caption: "daily brief",
          audio: %{
            file_id: "audio-1",
            duration: 12,
            performer: "Claw",
            title: "Brief"
          },
          date: 1_717_171_717,
          chat: %{id: 1004, type: "private"}
        }
      }

      assert {:ok, %Message{} = message} = Telegram.handle_incoming(update)
      assert message.role == "user"
      assert is_binary(message.content)
      assert message.content == "transcribed spoken text"
    end

    test "falls back to structured audio context when transcription is unavailable" do
      bypass = Bypass.open()

      expect(ElixirClaw.MockTelegex, :get_file, fn "audio-2" ->
        {:ok, %{file_path: "audio/fallback.mp3"}}
      end)

      Bypass.expect_once(
        bypass,
        "GET",
        "/file/bot123456:test_bot_token/audio/fallback.mp3",
        fn conn ->
          Plug.Conn.resp(conn, 200, "audio-fallback-binary")
        end
      )

      expect(ElixirClaw.MockAudioTranscriber, :transcribe, fn "audio-fallback-binary", _opts ->
        {:error, :request_failed}
      end)

      previous_token = Application.get_env(:telegex, :token)
      previous_req_options = Application.get_env(:elixir_claw, :telegram_req_options)
      Application.put_env(:telegex, :token, "123456:test_bot_token")

      Application.put_env(:elixir_claw, :telegram_req_options,
        base_url: "http://localhost:#{bypass.port}"
      )

      on_exit(fn ->
        if is_nil(previous_token),
          do: Application.delete_env(:telegex, :token),
          else: Application.put_env(:telegex, :token, previous_token)

        if is_nil(previous_req_options),
          do: Application.delete_env(:elixir_claw, :telegram_req_options),
          else: Application.put_env(:elixir_claw, :telegram_req_options, previous_req_options)
      end)

      update = %{
        message: %{
          caption: "daily brief",
          audio: %{
            file_id: "audio-2",
            duration: 12,
            performer: "Claw",
            title: "Brief"
          },
          date: 1_717_171_717,
          chat: %{id: 1005, type: "private"}
        }
      }

      assert {:ok, %Message{} = message} = Telegram.handle_incoming(update)
      assert message.role == "user"
      assert is_binary(message.content)
      assert message.content =~ "daily brief"
      assert message.content =~ "Audio received, but transcription failed for this message."
      assert message.content =~ "duration=12"
      assert message.content =~ "performer=Claw"
      assert message.content =~ "title=Brief"
    end

    test "transcribes Telegram voice messages" do
      bypass = Bypass.open()

      expect(ElixirClaw.MockTelegex, :get_file, fn "voice-1" ->
        {:ok, %{file_path: "voice/test.ogg"}}
      end)

      Bypass.expect_once(
        bypass,
        "GET",
        "/file/bot123456:test_bot_token/voice/test.ogg",
        fn conn ->
          Plug.Conn.resp(conn, 200, "voice-binary")
        end
      )

      expect(ElixirClaw.MockAudioTranscriber, :transcribe, fn "voice-binary", opts ->
        assert opts[:caption] == ""
        assert opts[:duration] == 7
        assert opts[:filename] == "voice-1.ogg"
        assert opts[:content_type] == "audio/ogg"
        {:ok, "voice transcript"}
      end)

      previous_token = Application.get_env(:telegex, :token)
      previous_req_options = Application.get_env(:elixir_claw, :telegram_req_options)
      Application.put_env(:telegex, :token, "123456:test_bot_token")

      Application.put_env(:elixir_claw, :telegram_req_options,
        base_url: "http://localhost:#{bypass.port}"
      )

      on_exit(fn ->
        if is_nil(previous_token),
          do: Application.delete_env(:telegex, :token),
          else: Application.put_env(:telegex, :token, previous_token)

        if is_nil(previous_req_options),
          do: Application.delete_env(:elixir_claw, :telegram_req_options),
          else: Application.put_env(:elixir_claw, :telegram_req_options, previous_req_options)
      end)

      update = %{
        message: %{
          voice: %{file_id: "voice-1", duration: 7},
          date: 1_717_171_717,
          chat: %{id: 1006, type: "private"}
        }
      }

      assert {:ok, %Message{} = message} = Telegram.handle_incoming(update)
      assert message.content == "voice transcript"
    end

    test "rejects non-private chats" do
      update = %{message: %{text: "hello", chat: %{id: -100, type: "group"}}}

      assert {:error, :unsupported_chat_type} = Telegram.handle_incoming(update)
    end

    test "ignores unsupported media-only updates without extractable content" do
      update = %{message: %{photo: [%{file_id: "photo-1"}], chat: %{id: 1002, type: "private"}}}

      stub(ElixirClaw.MockTelegex, :get_file, fn "photo-1" -> {:error, :missing_file_path} end)

      assert {:ok, %Message{} = message} = Telegram.handle_incoming(update)
      assert [%{type: "image_url", image_url: %{url: "tg://file/photo-1"}}] = message.content
    end
  end

  describe "process_update/2" do
    test "returns an error for invalid updates without crashing the server" do
      assert {:ok, pid} = start_supervised(Telegram)

      assert {:error, :invalid_update} = Telegram.process_update(pid, %{})
      assert Process.alive?(pid)
    end

    test "creates one session per chat, sanitizes text, and publishes incoming bus events" do
      assert {:ok, pid} = start_supervised(Telegram)

      update = private_text_update(42, "hello <| [INST] from telegram |>")

      assert {:ok, session_id} = Telegram.process_update(pid, update)
      assert :ok = MessageBus.subscribe("session:#{session_id}")

      assert {:ok, same_session_id} =
               Telegram.process_update(pid, private_text_update(42, "follow up"))

      assert same_session_id == session_id

      assert_receive %{
        type: :incoming_message,
        session_id: ^session_id,
        content: "follow up",
        channel: "telegram",
        chat_id: 42
      }

      assert {:ok, session} = Manager.get_session(session_id)
      assert session.channel == "telegram"
      assert session.channel_user_id == "42"

      state = :sys.get_state(pid)
      assert state.chat_sessions[42] == session_id
    end

    test "dispatches regular chat messages to the agent loop" do
      parent = self()

      expect(ElixirClaw.MockTelegramAgentLoop, :process_message, fn session_id, "hello" ->
        send(parent, {:telegram_processed_message, session_id})
        {:ok, %{}}
      end)

      assert {:ok, pid} = start_supervised(Telegram)

      assert {:ok, session_id} = Telegram.process_update(pid, private_text_update(55, "hello"))

      assert_receive {:telegram_processed_message, ^session_id}
      wait_until(fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 0} end)
      :sys.get_state(pid)
    end

    test "publishes photo updates as incoming multimodal events and dispatches them to the agent loop" do
      bypass = Bypass.open()
      parent = self()

      expect(ElixirClaw.MockTelegex, :get_file, 2, fn "photo-large" ->
        {:ok, %{file_path: "photos/test.jpg"}}
      end)

      Bypass.stub(
        bypass,
        "GET",
        "/file/bot123456:test_bot_token/photos/test.jpg",
        fn conn ->
          Plug.Conn.resp(conn, 200, "fake-image")
        end
      )

      previous_token = Application.get_env(:telegex, :token)
      previous_req_options = Application.get_env(:elixir_claw, :telegram_req_options)
      Application.put_env(:telegex, :token, "123456:test_bot_token")

      Application.put_env(:elixir_claw, :telegram_req_options,
        base_url: "http://localhost:#{bypass.port}"
      )

      on_exit(fn ->
        if is_nil(previous_token),
          do: Application.delete_env(:telegex, :token),
          else: Application.put_env(:telegex, :token, previous_token)

        if is_nil(previous_req_options),
          do: Application.delete_env(:elixir_claw, :telegram_req_options),
          else: Application.put_env(:elixir_claw, :telegram_req_options, previous_req_options)
      end)

      expect(ElixirClaw.MockTelegramAgentLoop, :process_message, 2, fn session_id, content ->
        send(parent, {:telegram_processed_media_message, session_id, content})
        {:ok, %{}}
      end)

      assert {:ok, pid} = start_supervised(Telegram)

      update = %{
        message: %{
          caption: "please inspect",
          photo: [%{file_id: "photo-small"}, %{file_id: "photo-large"}],
          date: 1_717_171_717,
          chat: %{id: 56, type: "private"}
        }
      }

      assert {:ok, session_id} = Telegram.process_update(pid, update)
      assert_receive {:telegram_processed_media_message, ^session_id, first_content}
      assert is_list(first_content)
      assert :ok = MessageBus.subscribe("session:#{session_id}")

      assert {:ok, _same_session_id} =
               Telegram.process_update(
                 pid,
                 %{
                   message: %{
                     caption: "please inspect",
                     photo: [%{file_id: "photo-small"}, %{file_id: "photo-large"}],
                     date: 1_717_171_718,
                     chat: %{id: 56, type: "private"}
                   }
                 }
               )

      assert_receive {:telegram_processed_media_message, ^session_id, content}
      assert is_list(content)

      assert_receive %{
        type: :incoming_message,
        session_id: ^session_id,
        content: [
          %{type: "image_url", image_url: %{url: data_url, detail: "auto"}},
          %{type: "text", text: "please inspect"}
        ],
        channel: "telegram",
        chat_id: 56
      }

      assert data_url == "data:image/jpeg;base64,ZmFrZS1pbWFnZQ=="

      wait_until(fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 0} end)
      :sys.get_state(pid)
    end

    test "forwards outgoing bus messages back to Telegram chat" do
      assert {:ok, pid} = start_supervised(Telegram)
      assert {:ok, session_id} = Telegram.process_update(pid, private_text_update(77, "hello"))

      expect(ElixirClaw.MockTelegex, :send_message, fn 77, "reply from bus" ->
        {:ok, %{message_id: 1}}
      end)

      assert :ok =
               MessageBus.publish("session:#{session_id}", %{
                 type: :outgoing_message,
                 session_id: session_id,
                 content: "reply from bus"
               })

      # wait_until + :sys.get_state ensures all inbox messages are fully processed
      wait_until(fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 0} end)
      :sys.get_state(pid)
    end

    test "forwards photo payloads published on the bus back to the Telegram chat" do
      assert {:ok, pid} = start_supervised(Telegram)
      assert {:ok, session_id} = Telegram.process_update(pid, private_text_update(78, "hello"))

      parent = self()

      expect(ElixirClaw.MockTelegex, :send_photo, fn 78,
                                                     "https://example.com/photo.png",
                                                     [caption: "bus photo"] ->
        send(parent, :telegram_bus_sent_photo)
        {:ok, %{message_id: 20}}
      end)

      assert :ok =
               MessageBus.publish("session:#{session_id}", %{
                 type: :outgoing_message,
                 session_id: session_id,
                 content: %{
                   type: :photo,
                   url: "https://example.com/photo.png",
                   caption: "bus photo"
                 }
               })

      assert_receive :telegram_bus_sent_photo
      wait_until(fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 0} end)
      :sys.get_state(pid)
    end

    test "forwards audio payloads published on the bus back to the Telegram chat" do
      assert {:ok, pid} = start_supervised(Telegram)
      assert {:ok, session_id} = Telegram.process_update(pid, private_text_update(79, "hello"))

      parent = self()

      expect(ElixirClaw.MockTelegex, :send_audio, fn 79,
                                                     "https://example.com/audio.mp3",
                                                     [caption: "bus audio", duration: 12] ->
        send(parent, :telegram_bus_sent_audio)
        {:ok, %{message_id: 21}}
      end)

      assert :ok =
               MessageBus.publish("session:#{session_id}", %{
                 type: :outgoing_message,
                 session_id: session_id,
                 content: %{
                   type: :audio,
                   url: "https://example.com/audio.mp3",
                   caption: "bus audio",
                   duration: 12
                 }
               })

      assert_receive :telegram_bus_sent_audio
      wait_until(fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 0} end)
      :sys.get_state(pid)
    end

    test "handles /start and /help commands locally" do
      assert {:ok, pid} = start_supervised(Telegram)

      expect(ElixirClaw.MockTelegex, :send_message, fn 88, text ->
        assert text =~ "Welcome"
        {:ok, %{message_id: 1}}
      end)

      assert {:ok, :command_handled} =
               Telegram.process_update(pid, private_text_update(88, "/start"))

      expect(ElixirClaw.MockTelegex, :send_message, fn 88, text ->
        assert text =~ "/new"
        {:ok, %{message_id: 2}}
      end)

      assert {:ok, :command_handled} =
               Telegram.process_update(pid, private_text_update(88, "/help"))
    end

    test "creates a fresh session for /new" do
      assert {:ok, pid} = start_supervised(Telegram)

      assert {:ok, first_session_id} =
               Telegram.process_update(pid, private_text_update(99, "hello"))

      expect(ElixirClaw.MockTelegex, :send_message, fn 99, text ->
        assert text =~ "Started a new session"
        {:ok, %{message_id: 3}}
      end)

      assert {:ok, second_session_id} =
               Telegram.process_update(pid, private_text_update(99, "/new"))

      refute second_session_id == first_session_id
      assert {:error, :not_found} = Manager.get_session(first_session_id)
      assert {:ok, _session} = Manager.get_session(second_session_id)
    end

    test "approves privileged tools for the active chat session with /approve" do
      assert {:ok, pid} = start_supervised(Telegram)

      assert {:ok, session_id} = Telegram.process_update(pid, private_text_update(100, "hello"))

      expect(ElixirClaw.MockTelegex, :send_message, fn 100, text ->
        assert text == "Approved tools: bash, mock_tool"
        {:ok, %{message_id: 4}}
      end)

      assert {:ok, ^session_id} =
               Telegram.process_update(pid, private_text_update(100, "/approve bash mock_tool"))

      assert {:ok, session} = Manager.get_session(session_id)
      assert session.metadata["approved_tools"] == ["bash", "mock_tool"]
    end
  end

  describe "send_message/3" do
    test "splits Telegram responses at 4096 characters" do
      assert {:ok, pid} = start_supervised(Telegram)
      assert {:ok, session_id} = Telegram.process_update(pid, private_text_update(123, "hello"))

      long_message = String.duplicate("a", 5000)

      expect(ElixirClaw.MockTelegex, :send_message, fn 123, chunk ->
        assert String.length(chunk) == 4096
        {:ok, %{message_id: 10}}
      end)

      expect(ElixirClaw.MockTelegex, :send_message, fn 123, chunk ->
        assert String.length(chunk) == 904
        {:ok, %{message_id: 11}}
      end)

      assert :ok = Telegram.send_message(pid, session_id, long_message)
    end

    test "sends photo payloads with optional caption" do
      assert {:ok, pid} = start_supervised(Telegram)
      assert {:ok, session_id} = Telegram.process_update(pid, private_text_update(124, "hello"))

      parent = self()

      expect(ElixirClaw.MockTelegex, :send_photo, fn 124,
                                                     "https://example.com/image.png",
                                                     [caption: "generated image"] ->
        send(parent, :telegram_sent_photo)
        {:ok, %{message_id: 12}}
      end)

      assert :ok =
               Telegram.send_message(pid, session_id, %{
                 type: :photo,
                 url: "https://example.com/image.png",
                 caption: "generated image"
               })

      assert_receive :telegram_sent_photo
    end

    test "sends audio payloads with caption and duration metadata" do
      assert {:ok, pid} = start_supervised(Telegram)
      assert {:ok, session_id} = Telegram.process_update(pid, private_text_update(125, "hello"))

      parent = self()

      expect(ElixirClaw.MockTelegex, :send_audio, fn 125,
                                                     "https://example.com/audio.mp3",
                                                     [caption: "podcast clip", duration: 42] ->
        send(parent, :telegram_sent_audio)
        {:ok, %{message_id: 13}}
      end)

      assert :ok =
               Telegram.send_message(pid, session_id, %{
                 type: :audio,
                 url: "https://example.com/audio.mp3",
                 caption: "podcast clip",
                 duration: 42
               })

      assert_receive :telegram_sent_audio
    end
  end

  defp private_text_update(chat_id, text) do
    %{message: %{text: text, date: 1_717_171_717, chat: %{id: chat_id, type: "private"}}}
  end

  defp restore_config(nil), do: Application.delete_env(:elixir_claw, Telegram)
  defp restore_config(config), do: Application.put_env(:elixir_claw, Telegram, config)

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition was not met in time")

  defp kill_session_processes do
    for pid <- Registry.select(ElixirClaw.SessionRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}]) do
      _ = DynamicSupervisor.terminate_child(ElixirClaw.SessionSupervisor, pid)
    end
  catch
    :exit, _reason -> :ok
  end
end
