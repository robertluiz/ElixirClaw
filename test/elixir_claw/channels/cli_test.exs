defmodule ElixirClaw.Channels.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ElixirClaw.Channels.CLI
  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.Session, as: SessionSchema
  alias ElixirClaw.Session.Manager
  alias ElixirClaw.Types.Message

  setup do
    Repo.reset!()
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

    test "lists available specialized task agents with /agents" do
      assert {:task_agents, task_agents_text} = CLI.handle_incoming("/agents")

      assert task_agents_text =~ "feature-builder"
      assert task_agents_text =~ "bug-fixer"
      assert task_agents_text =~ "code-reviewer"
    end

    test "activates a specialized task agent with /agent <name>" do
      assert {:ok, session_id} = Manager.start_session(base_attrs(channel_user_id: "agent-user"))

      assert {:active_task_agent, "feature-builder"} =
               CLI.handle_incoming(%{text: "/agent feature-builder", session_id: session_id})

      assert {:ok, session} = Manager.get_session(session_id)
      assert session.metadata["active_task_agent"] == "feature-builder"
    end

    test "shows the current specialized task agent with /agent" do
      assert {:ok, session_id} = Manager.start_session(base_attrs(channel_user_id: "agent-current"))
      assert :ok = Manager.set_task_agent(session_id, "bug-fixer")

      assert {:active_task_agent, "bug-fixer"} =
               CLI.handle_incoming(%{text: "/agent", session_id: session_id})
    end

    test "disables the current specialized task agent with /agent off" do
      assert {:ok, session_id} = Manager.start_session(base_attrs(channel_user_id: "agent-off"))
      assert :ok = Manager.set_task_agent(session_id, "bug-fixer")

      assert {:active_task_agent, :none} =
               CLI.handle_incoming(%{text: "/agent off", session_id: session_id})

      assert {:ok, session} = Manager.get_session(session_id)
      refute Map.has_key?(session.metadata, "active_task_agent")
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

    test "includes the active specialized task agent in session info" do
      assert {:ok, session_id} = Manager.start_session(base_attrs(channel_user_id: "cli-agent-info"))
      assert :ok = Manager.set_task_agent(session_id, "test-writer")

      assert {:session, session_text} =
               CLI.handle_incoming(%{text: "/session", session_id: session_id})

      assert session_text =~ "task agent: test-writer"
    end

    test "returns an error when /session is requested without a session id" do
      assert {:error, :missing_session_id} = CLI.handle_incoming(%{text: "/session"})
    end

    test "approves privileged tools for the active session with /approve" do
      assert {:ok, session_id} = Manager.start_session(base_attrs(channel_user_id: "approve-user"))

      assert {:approved_tools, ["bash", "privileged_tool"]} =
               CLI.handle_incoming(%{text: "/approve bash privileged_tool", session_id: session_id})

      assert {:ok, session} = Manager.get_session(session_id)
      assert session.metadata["approved_tools"] == ["bash", "privileged_tool"]
    end

    test "returns an error when /approve is requested without a session id" do
      assert {:error, :missing_session_id} = CLI.handle_incoming(%{text: "/approve bash"})
    end

    test "returns an error when /approve is missing tool names" do
      assert {:ok, session_id} = Manager.start_session(base_attrs(channel_user_id: "approve-missing"))
      assert {:error, :missing_tool_names} = CLI.handle_incoming(%{text: "/approve", session_id: session_id})
    end

    test "returns an error when /agent references an unknown specialized task agent" do
      assert {:ok, session_id} = Manager.start_session(base_attrs(channel_user_id: "agent-missing"))

      assert {:error, :unknown_task_agent} =
               CLI.handle_incoming(%{text: "/agent imaginary-agent", session_id: session_id})
    end

    test "creates and activates a runtime specialized task agent with /agent create" do
      assert {:ok, session_id} = Manager.start_session(base_attrs(channel_user_id: "agent-create"))

      command =
        "/agent create triage-helper --description First-pass triage --prompt Triage quickly --tasks classify,severity --model gpt-4o-mini --tier cheap --skill triage-skill --mcp docs --activate"

      assert {:task_agent_created, created_name} =
               CLI.handle_incoming(%{text: command, session_id: session_id})

      assert created_name == "triage-helper"

      assert {:ok, session} = Manager.get_session(session_id)
      assert session.metadata["active_task_agent"] == "triage-helper"

      assert [runtime_agent] = session.metadata["runtime_task_agents"]
      assert runtime_agent["skills"] == [
               %{
                 "name" => "triage-skill",
                 "content" => "Skill triage-skill attached to task agent triage-helper.",
                 "token_estimate" => 0
               }
             ]
      assert runtime_agent["mcp_servers"] == ["docs"]
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

end
