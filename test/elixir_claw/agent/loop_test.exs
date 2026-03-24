defmodule ElixirClaw.Agent.LoopTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Mox

  alias ElixirClaw.Agent.ContextBuilder
  alias ElixirClaw.Agent.Loop
  alias ElixirClaw.Bus.MessageBus
  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.Message, as: MessageSchema
  alias ElixirClaw.Schema.Session, as: SessionSchema
  alias ElixirClaw.Session.Manager
  alias ElixirClaw.Tools.Registry, as: ToolRegistry
  alias ElixirClaw.Types.{ProviderResponse, TokenUsage, ToolCall}

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    Mox.set_mox_global()

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    create_test_tables!()
    Repo.delete_all(MessageSchema)
    Repo.delete_all(SessionSchema)
    kill_session_processes()

    registry_name = :agent_loop_test_registry
    start_supervised!({ToolRegistry, name: registry_name})

    previous_config = Application.get_env(:elixir_claw, Loop)

    Application.put_env(:elixir_claw, Loop,
      provider: ElixirClaw.MockProvider,
      tool_registry: registry_name,
      max_iterations: 10
    )

    on_exit(fn ->
      restore_loop_config(previous_config)
      kill_session_processes()
    end)

    %{tool_registry: registry_name}
  end

  describe "process_message/2" do
    test "sanitizes input, includes persisted history, publishes the response, records tokens, and persists user + assistant messages" do
      assert {:ok, session_id} =
               Manager.start_session(base_attrs(channel_user_id: "loop-success"))

      insert_message!(session_id, %{role: "assistant", content: "Earlier answer"})

      topic = "session:#{session_id}"
      raw_message = "hello <| [INST] world |>"
      sanitized_message = ContextBuilder.sanitize_user_content(raw_message)

      assert :ok = MessageBus.subscribe(topic)

      expect(ElixirClaw.MockProvider, :chat, fn messages, opts ->
        assert [
                 %{role: "assistant", content: "Earlier answer"},
                 %{role: "user", content: ^sanitized_message}
               ] = Enum.map(messages, &Map.take(&1, [:role, :content]))

        assert Keyword.get(opts, :model) == "gpt-4o-mini"
        refute Keyword.has_key?(opts, :tools)

        {:ok,
         %ProviderResponse{
           content: "Hello back",
           token_usage: %TokenUsage{input: 11, output: 7, total: 18}
         }}
      end)

      log =
        capture_log(fn ->
          assert {:ok, %ProviderResponse{content: "Hello back"}} =
                   Loop.process_message(session_id, raw_message)
        end)

      assert log =~ "Session #{session_id}: 11 in / 7 out tokens"

      assert_receive %{type: :outgoing_message, content: "Hello back", session_id: ^session_id}

      persisted_messages = persisted_messages(session_id)

      assert length(persisted_messages) == 3

      assert Enum.any?(
               persisted_messages,
               &(&1.role == "assistant" and &1.content == "Earlier answer")
             )

      assert Enum.any?(
               persisted_messages,
               &(&1.role == "user" and &1.content == sanitized_message)
             )

      assert Enum.any?(
               persisted_messages,
               &(&1.role == "assistant" and &1.content == "Hello back")
             )

      persisted_session = Repo.get!(SessionSchema, session_id)
      assert persisted_session.token_count_in == 11
      assert persisted_session.token_count_out == 7
    end

    test "executes tool calls, appends tool results, re-queries the provider, and records tokens for each provider call",
         %{tool_registry: tool_registry} do
      assert :ok = ToolRegistry.register(tool_registry, LoopMockToolAdapter)
      assert {:ok, session_id} = Manager.start_session(base_attrs(channel_user_id: "loop-tool"))

      topic = "session:#{session_id}"
      assert :ok = MessageBus.subscribe(topic)

      expect(ElixirClaw.MockTool, :execute, fn %{"query" => "otp"}, context ->
        assert context["session_id"] == session_id
        {:ok, "tool-result:otp"}
      end)

      expect(ElixirClaw.MockProvider, :chat, 2, fn messages, opts ->
        call_number = Process.get(:loop_provider_call_number, 0)
        Process.put(:loop_provider_call_number, call_number + 1)

        case call_number do
          0 ->
            assert [%{role: "user", content: "Run the tool"}] =
                     Enum.map(messages, &Map.take(&1, [:role, :content]))

            assert Keyword.get(opts, :tools) == [
                     %{
                       type: "function",
                       function: %{
                         name: "mock_tool",
                         description: "Search mock data",
                         parameters: %{
                           "type" => "object",
                           "properties" => %{"query" => %{"type" => "string"}},
                           "required" => ["query"]
                         }
                       }
                     }
                   ]

            {:ok,
             %ProviderResponse{
               content: nil,
               tool_calls: [
                 %ToolCall{id: "tool-call-1", name: "mock_tool", arguments: %{"query" => "otp"}}
               ],
               token_usage: %TokenUsage{input: 5, output: 3, total: 8}
             }}

          1 ->
            assert [
                     %{role: "user", content: "Run the tool"},
                     %{
                       role: "assistant",
                       tool_calls: [
                         %ToolCall{
                           id: "tool-call-1",
                           name: "mock_tool",
                           arguments: %{"query" => "otp"}
                         }
                       ]
                     },
                     %{role: "tool", tool_call_id: "tool-call-1", content: "tool-result:otp"}
                   ] =
                     Enum.map(
                       messages,
                       &Map.take(&1, [:role, :content, :tool_calls, :tool_call_id])
                     )

            {:ok,
             %ProviderResponse{
               content: "Tool complete",
               token_usage: %TokenUsage{input: 2, output: 4, total: 6}
             }}
        end
      end)

      assert {:ok, %ProviderResponse{content: "Tool complete"}} =
               Loop.process_message(session_id, "Run the tool")

      assert_receive %{type: :outgoing_message, content: "Tool complete", session_id: ^session_id}

      persisted_session = Repo.get!(SessionSchema, session_id)
      assert persisted_session.token_count_in == 7
      assert persisted_session.token_count_out == 7

      persisted_messages = persisted_messages(session_id)

      assert length(persisted_messages) == 2
      assert Enum.any?(persisted_messages, &(&1.role == "user" and &1.content == "Run the tool"))

      assert Enum.any?(
               persisted_messages,
               &(&1.role == "assistant" and &1.content == "Tool complete")
             )
    end

    test "stops recursive tool handling when max_iterations is reached", %{
      tool_registry: tool_registry
    } do
      Application.put_env(:elixir_claw, Loop,
        provider: ElixirClaw.MockProvider,
        tool_registry: tool_registry,
        max_iterations: 1
      )

      assert :ok = ToolRegistry.register(tool_registry, LoopMockToolAdapter)
      assert {:ok, session_id} = Manager.start_session(base_attrs(channel_user_id: "loop-max"))

      topic = "session:#{session_id}"
      assert :ok = MessageBus.subscribe(topic)

      expect(ElixirClaw.MockTool, :execute, fn %{"query" => "otp"}, _context ->
        {:ok, "tool-result:otp"}
      end)

      expect(ElixirClaw.MockProvider, :chat, 2, fn _messages, _opts ->
        call_number = Process.get(:max_iteration_provider_call_number, 0)
        Process.put(:max_iteration_provider_call_number, call_number + 1)

        {:ok,
         %ProviderResponse{
           content: nil,
           tool_calls: [
             %ToolCall{
               id: "tool-call-#{call_number}",
               name: "mock_tool",
               arguments: %{"query" => "otp"}
             }
           ],
           token_usage: %TokenUsage{input: 1, output: 1, total: 2}
         }}
      end)

      assert {:ok, %ProviderResponse{content: "Tool call limit reached."}} =
               Loop.process_message(session_id, "Keep calling tools")

      assert_receive %{
        type: :outgoing_message,
        content: "Tool call limit reached.",
        session_id: ^session_id
      }

      persisted_session = Repo.get!(SessionSchema, session_id)
      assert persisted_session.token_count_in == 2
      assert persisted_session.token_count_out == 2
    end

    test "publishes a user-friendly error when the provider fails" do
      assert {:ok, session_id} = Manager.start_session(base_attrs(channel_user_id: "loop-error"))

      topic = "session:#{session_id}"
      assert :ok = MessageBus.subscribe(topic)

      expect(ElixirClaw.MockProvider, :chat, fn _messages, _opts ->
        {:error, :upstream_timeout}
      end)

      assert {:error, :provider_error} = Loop.process_message(session_id, "Hello")

      assert_receive %{type: :error, message: "An error occurred. Please try again."}

      refute_receive %{message: "upstream_timeout"}

      assert [%{role: "user", content: "Hello"}] =
               session_id
               |> persisted_messages()
               |> Enum.map(&Map.take(&1, [:role, :content]))

      persisted_session = Repo.get!(SessionSchema, session_id)
      assert persisted_session.token_count_in == 0
      assert persisted_session.token_count_out == 0
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

  defp insert_message!(session_id, attrs) do
    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.put(:session_id, session_id)
      |> Map.put_new(:tool_calls, nil)
      |> Map.put_new(:tool_call_id, nil)
      |> Map.put_new(:token_count, ContextBuilder.estimate_tokens(Map.get(attrs, :content)))

    %MessageSchema{}
    |> MessageSchema.changeset(attrs)
    |> Repo.insert!()
  end

  defp persisted_messages(session_id) do
    from(message in MessageSchema,
      where: message.session_id == ^session_id,
      order_by: [asc: message.inserted_at, asc: message.id]
    )
    |> Repo.all()
  end

  defp restore_loop_config(nil), do: Application.delete_env(:elixir_claw, Loop)
  defp restore_loop_config(config), do: Application.put_env(:elixir_claw, Loop, config)

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

defmodule LoopMockToolAdapter do
  @behaviour ElixirClaw.Tool

  def name, do: "mock_tool"
  def description, do: "Search mock data"

  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{"query" => %{"type" => "string"}},
      "required" => ["query"]
    }
  end

  def max_output_bytes, do: 65_536
  def timeout_ms, do: 100

  defdelegate execute(params, context), to: ElixirClaw.MockTool
end
