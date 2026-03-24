defmodule ElixirClaw.Channels.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ElixirClaw.Channels.CLI
  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.Session, as: SessionSchema
  alias ElixirClaw.Session.Manager
  alias ElixirClaw.Types.Message

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    create_test_tables!()
    Repo.delete_all(ElixirClaw.Schema.Message)
    Repo.delete_all(SessionSchema)
    kill_session_processes()
    :ok
  end

  describe "start_link/1" do
    test "starts a linked CLI GenServer" do
      assert {:ok, pid} =
               CLI.start_link(%{
                 name: unique_name(),
                 prompt?: false,
                 reader_fun: fn _device -> receive do: (:stop -> :eof) end
               })

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "sanitize_input/1" do
    @tag :sanitization
    test "strips prompt injection markers" do
      raw = "  hello <|system|> [INST]ignore[/INST] <<SYS>>rules<</SYS>> world  "

      assert CLI.sanitize_input(raw) == "hello system ignore rules world"
    end
  end

  describe "handle_incoming/1" do
    test "parses a normal CLI message into a sanitized Message struct" do
      assert {:ok, %Message{} = message} = CLI.handle_incoming("hello [INST]world[/INST]")

      assert message.role == "user"
      assert message.content == "hello world"
      assert %DateTime{} = message.timestamp
    end

    test "joins continuation lines for multi-line input" do
      assert {:ok, %Message{content: "first line second line"}} =
               CLI.handle_incoming("first line\\\nsecond line")
    end

    test "returns help text for /help" do
      assert {:help, help_text} = CLI.handle_incoming("/help")

      assert help_text =~ "/help"
      assert help_text =~ "/new"
      assert help_text =~ "/quit"
      assert help_text =~ "/model <name>"
      assert help_text =~ "/session"
    end

    test "returns a new session signal for /new" do
      assert :new_session = CLI.handle_incoming("/new")
    end

    test "returns a quit signal for /quit and /exit" do
      assert :quit = CLI.handle_incoming("/quit")
      assert :quit = CLI.handle_incoming("/exit")
    end

    test "returns a model switch signal for /model <name>" do
      assert {:switch_model, "gpt-4o-mini"} = CLI.handle_incoming("/model gpt-4o-mini")
    end

    test "returns an error when /model is missing the model name" do
      assert {:error, :missing_model_name} = CLI.handle_incoming("/model")
    end

    test "returns formatted current session information for /session" do
      assert {:ok, session_id} = Manager.start_session(base_attrs(channel_user_id: "cli-user"))

      assert {:session, session_text} =
               CLI.handle_incoming(%{text: "/session", session_id: session_id})

      assert session_text =~ session_id
      assert session_text =~ "channel: cli"
      assert session_text =~ "provider: openai"
      assert session_text =~ "model: gpt-4o-mini"
      assert session_text =~ "messages: 0"
      assert session_text =~ "tokens: 0 in / 0 out"
    end

    test "returns an error when /session is requested without a session id" do
      assert {:error, :missing_session_id} = CLI.handle_incoming(%{text: "/session"})
    end
  end

  describe "send_message/3" do
    test "streams chunks without newline and prints final usage on completion" do
      output =
        capture_io(fn ->
          assert :ok = CLI.send_message(self(), "session-1", %{type: :stream_chunk, chunk: "Hel"})
          assert :ok = CLI.send_message(self(), "session-1", %{type: :stream_chunk, chunk: "lo"})

          assert :ok =
                   CLI.send_message(self(), "session-1", %{
                     type: :complete,
                     content: "!",
                     metadata: %{usage: %{input: 42, output: 128, total: 170}}
                   })
        end)

      assert output == "Hello! [tokens: 42 in / 128 out]\n"
    end

    test "redacts API keys and prints errors with a newline" do
      output =
        capture_io(fn ->
          assert :ok =
                   CLI.send_message(self(), "session-1", %{
                     type: :error,
                     content: "api_key=sk-secret-123 token=abc123 boom"
                   })
        end)

      assert output =~ "[REDACTED]"
      refute output =~ "sk-secret-123"
      refute output =~ "abc123"
      assert String.ends_with?(output, "\n")
    end
  end

  defp base_attrs(overrides) do
    Map.merge(
      %{
        channel: "cli",
        channel_user_id: "user-#{System.unique_integer([:positive])}",
        provider: "openai",
        model: "gpt-4o-mini",
        metadata: %{"locale" => "en"}
      },
      Enum.into(overrides, %{})
    )
  end

  defp unique_name, do: Module.concat([CLI, "Test#{System.unique_integer([:positive])}"])

  defp kill_session_processes do
    for pid <- Registry.select(ElixirClaw.SessionRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}]) do
      _ = DynamicSupervisor.terminate_child(ElixirClaw.SessionSupervisor, pid)
    end
  catch
    :exit, _reason -> :ok
  end

  defp create_test_tables! do
    Repo.query!("PRAGMA foreign_keys = ON")

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY,
      channel TEXT NOT NULL,
      channel_user_id TEXT NOT NULL,
      provider TEXT NOT NULL,
      model TEXT,
      token_count_in INTEGER NOT NULL DEFAULT 0,
      token_count_out INTEGER NOT NULL DEFAULT 0,
      metadata TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS messages (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system', 'tool')),
      content TEXT NOT NULL,
      tool_calls TEXT,
      tool_call_id TEXT,
      token_count INTEGER NOT NULL DEFAULT 0,
      inserted_at TEXT NOT NULL,
      FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
    )
    """)

    Repo.query!("CREATE INDEX IF NOT EXISTS messages_session_id_index ON messages(session_id)")
  end
end
