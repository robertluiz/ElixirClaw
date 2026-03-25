Mox.defmock(ElixirClaw.MockTelegex, for: ElixirClaw.Channels.Telegram.API)

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
      provider: "openai",
      model: "gpt-4o-mini",
      start_polling: false
    )

    on_exit(fn ->
      restore_config(previous_config)
      kill_session_processes()
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
      assert {:ok, pid} = start_supervised(Telegram)
      assert Process.alive?(pid)
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

    test "rejects non-private chats" do
      update = %{message: %{text: "hello", chat: %{id: -100, type: "group"}}}

      assert {:error, :unsupported_chat_type} = Telegram.handle_incoming(update)
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
