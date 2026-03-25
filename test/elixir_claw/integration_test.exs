defmodule ElixirClaw.IntegrationTest do
  use ExUnit.Case, async: false

  import Mox

  alias ElixirClaw.Agent.ContextBuilder
  alias ElixirClaw.Agent.Loop
  alias ElixirClaw.Agent.Memory
  alias ElixirClaw.Bus.MessageBus
  alias ElixirClaw.Channels.CLI
  alias ElixirClaw.MCP.ToolWrapper
  alias ElixirClaw.Repo
  alias ElixirClaw.Security.Canary
  alias ElixirClaw.Schema.Message, as: MessageSchema
  alias ElixirClaw.Schema.Session, as: SessionSchema
  alias ElixirClaw.Session.Manager
  alias ElixirClaw.Test.Factory
  alias ElixirClaw.Test.SecurityHelpers
  alias ElixirClaw.Tools.Registry, as: ToolRegistry
  alias ElixirClaw.Types.{Message, ProviderResponse, TokenUsage, ToolCall}

  @moduletag :integration

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    Mox.set_mox_global()

    Repo.reset!()
    Repo.delete_all(MessageSchema)
    Repo.delete_all(SessionSchema)
    kill_session_processes()

    registry_name = :integration_test_registry
    start_supervised!({ToolRegistry, name: registry_name})

    previous_loop_config = Application.get_env(:elixir_claw, Loop)
    previous_http_client = Application.get_env(:elixir_claw, :mcp_http_client_module)
    previous_stdio_client = Application.get_env(:elixir_claw, :mcp_stdio_client_module)

    Application.put_env(:elixir_claw, Loop,
      provider: ElixirClaw.MockProvider,
      tool_registry: registry_name,
      max_iterations: 10
    )

    Application.put_env(:elixir_claw, :mcp_http_client_module, ElixirClaw.MockHTTPClient)
    Application.put_env(:elixir_claw, :mcp_stdio_client_module, ElixirClaw.MockStdioClient)

    on_exit(fn ->
      restore_loop_config(previous_loop_config)
      restore_env(:mcp_http_client_module, previous_http_client)
      restore_env(:mcp_stdio_client_module, previous_stdio_client)
      kill_session_processes()
    end)

    %{tool_registry: registry_name}
  end

  test "simple chat flows from CLI input through Agent Loop and publishes the assistant reply" do
    assert {:ok, session_id} =
             Manager.start_session(base_attrs(channel_user_id: "integration-cli"))

    assert :ok = MessageBus.subscribe("channel:cli")
    assert :ok = MessageBus.subscribe("session:#{session_id}")

    parent = self()

    {:ok, cli_pid} =
      CLI.start_link(%{
        name: unique_cli_name(),
        prompt?: false,
        session_id: session_id,
        reader_fun: fn _device ->
          receive do
            :stop -> :eof
          end
        end,
        on_input: fn
          {:ok, %Message{} = message} = result ->
            send(parent, {:cli_input_result, result})
            Loop.process_message(session_id, message.content)

          result ->
            send(parent, {:cli_input_result, result})
        end
      })

    on_exit(fn -> if Process.alive?(cli_pid), do: GenServer.stop(cli_pid) end)

    allow(ElixirClaw.MockProvider, self(), cli_pid)

    expect(ElixirClaw.MockProvider, :chat, fn messages, opts ->
      assert [
               %{role: "system", content: system_prompt},
               %{role: "user", content: user_content}
             ] =
               Enum.map(messages, &Map.take(&1, [:role, :content]))

      assert system_prompt =~ Canary.token_for_session(session_id)
      assert user_content == "<untrusted_user_input>hello world</untrusted_user_input>"

      assert Keyword.get(opts, :model) == "gpt-4o-mini"

      {:ok,
       %ProviderResponse{
         content: "Hello",
         token_usage: %TokenUsage{input: 12, output: 8, total: 20}
       }}
    end)

    send(cli_pid, {:cli_input, "hello [INST] world"})

    assert_receive {:cli_input_result, {:ok, %Message{content: "hello world"}}}
    assert_receive %{type: :incoming_message, content: "hello world"}
    assert_receive %{type: :outgoing_message, content: "Hello", session_id: ^session_id}

    persisted = MapSet.new(Enum.map(persisted_messages(session_id), &{&1.role, &1.content}))

    assert MapSet.member?(persisted, {"user", "hello world"})
    assert MapSet.member?(persisted, {"assistant", "Hello"})
  end

  test "tool call round-trip executes a registered tool and returns the final provider answer", %{
    tool_registry: tool_registry
  } do
    assert :ok = ToolRegistry.register(tool_registry, IntegrationMockToolAdapter)

    assert {:ok, session_id} =
             Manager.start_session(base_attrs(channel_user_id: "integration-tool"))

    assert :ok = MessageBus.subscribe("session:#{session_id}")

    expect(ElixirClaw.MockTool, :execute, fn %{"query" => "otp"}, context ->
      assert context["session_id"] == session_id
      {:ok, "tool-result:otp"}
    end)

    expect(ElixirClaw.MockProvider, :chat, 2, fn messages, opts ->
      case Process.get(:tool_round_trip_call, 0) do
        0 ->
          Process.put(:tool_round_trip_call, 1)

          assert [
                   %{role: "system", content: _system_prompt},
                   %{role: "user", content: "<untrusted_user_input>run tool</untrusted_user_input>"}
                 ] =
                   Enum.map(messages, &Map.take(&1, [:role, :content]))

          assert Keyword.get(opts, :tools) == [
                   %{
                     type: "function",
                     function: %{
                       name: "test_tool",
                       description: "Runs the integration mock tool",
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
               %ToolCall{id: "tool-1", name: "test_tool", arguments: %{"query" => "otp"}}
             ],
             token_usage: %TokenUsage{input: 4, output: 3, total: 7}
           }}

        1 ->
          assert [
                   %{role: "system", content: _system_prompt},
                   %{role: "user", content: "<untrusted_user_input>run tool</untrusted_user_input>"},
                   %{role: "assistant", tool_calls: [%ToolCall{id: "tool-1", name: "test_tool"}]},
                   %{
                     role: "tool",
                     tool_call_id: "tool-1",
                     content: "<untrusted_tool_output>tool-result:otp</untrusted_tool_output>"
                   }
                  ] =
                    Enum.map(
                      messages,
                     &Map.take(&1, [:role, :content, :tool_calls, :tool_call_id])
                   )

          {:ok,
           %ProviderResponse{
             content: "Tool complete",
             token_usage: %TokenUsage{input: 2, output: 5, total: 7}
           }}
      end
    end)

    assert {:ok, %ProviderResponse{content: "Tool complete"}} =
             Loop.process_message(session_id, "run tool")

    assert_receive %{type: :outgoing_message, content: "Tool complete", session_id: ^session_id}

    persisted = MapSet.new(Enum.map(persisted_messages(session_id), &{&1.role, &1.content}))

    assert MapSet.member?(persisted, {"user", "run tool"})
    assert MapSet.member?(persisted, {"assistant", "Tool complete"})
  end

  test "multi-turn conversation rebuilds context with growing history across turns" do
    assert {:ok, session_id} =
             Manager.start_session(base_attrs(channel_user_id: "integration-history"))

    expect(ElixirClaw.MockProvider, :chat, 2, fn messages, _opts ->
      case Process.get(:multi_turn_call, 0) do
        0 ->
          Process.put(:multi_turn_call, 1)

          assert [
                   %{role: "system", content: _system_prompt},
                   %{role: "user", content: "<untrusted_user_input>first turn</untrusted_user_input>"}
                 ] =
                   Enum.map(messages, &Map.take(&1, [:role, :content]))

          {:ok,
           %ProviderResponse{
             content: "first reply",
             token_usage: %TokenUsage{input: 3, output: 2, total: 5}
           }}

        1 ->
          history = MapSet.new(Enum.map(messages, &{&1.role, &1.content}))

          assert MapSet.member?(history, {"user", "<untrusted_user_input>first turn</untrusted_user_input>"})
          assert MapSet.member?(history, {"assistant", "first reply"})
          assert MapSet.member?(history, {"user", "<untrusted_user_input>second turn</untrusted_user_input>"})
          assert length(messages) == 4

          {:ok,
           %ProviderResponse{
             content: "second reply",
             token_usage: %TokenUsage{input: 4, output: 3, total: 7}
           }}
      end
    end)

    assert {:ok, %ProviderResponse{content: "first reply"}} =
             Loop.process_message(session_id, "first turn")

    assert {:ok, %ProviderResponse{content: "second reply"}} =
             Loop.process_message(session_id, "second turn")

    persisted = persisted_messages(session_id)

    assert Enum.count(persisted) == 4
    assert Enum.any?(persisted, &(&1.role == "assistant" and &1.content == "first reply"))
    assert Enum.any?(persisted, &(&1.role == "assistant" and &1.content == "second reply"))
  end

  test "session management supports /new while previously persisted sessions remain retrievable" do
    assert {:ok, old_session_id} =
             Manager.start_session(base_attrs(channel_user_id: "existing-user"))

    assert :new_session = CLI.handle_incoming("/new")
    assert {:ok, new_session_id} = Manager.start_session(base_attrs(channel_user_id: "new-user"))

    refute new_session_id == old_session_id

    assert %SessionSchema{id: ^old_session_id, channel_user_id: "existing-user"} =
             Repo.get!(SessionSchema, old_session_id)

    assert {:ok, _old_session} = Manager.get_session(old_session_id)
    assert {:ok, _new_session} = Manager.get_session(new_session_id)
  end

  test "memory consolidation summarizes long histories and replaces archived messages" do
    session = Factory.insert_session!(channel_user_id: "memory-user")

    Factory.insert_message!(
      session_id: session.id,
      role: "user",
      content: String.duplicate("a", 80),
      token_count: 25
    )

    Factory.insert_message!(
      session_id: session.id,
      role: "assistant",
      content: String.duplicate("b", 80),
      token_count: 25
    )

    Factory.insert_message!(
      session_id: session.id,
      role: "user",
      content: String.duplicate("c", 80),
      token_count: 25
    )

    summary = "Conversation summary for archived integration messages."

    expect(ElixirClaw.MockProvider, :chat, fn messages, opts ->
      assert opts == []
      assert [%{role: "user", content: prompt}] = messages
      assert prompt =~ "Summarize this conversation:"
      assert prompt =~ "user: #{String.duplicate("a", 80)}"
      assert prompt =~ "assistant: #{String.duplicate("b", 80)}"
      assert prompt =~ "user: #{String.duplicate("c", 80)}"

      {:ok, %ProviderResponse{content: summary}}
    end)

    assert Memory.consolidation_needed?(session.id, threshold: 50)

    assert {:ok, %{summary: ^summary, messages_archived: 3}} =
             Memory.consolidate(session.id, ElixirClaw.MockProvider, threshold: 50)

    assert [
             %{
               role: "assistant",
               content: "<untrusted_memory_summary>" <> ^summary <> "</untrusted_memory_summary>"
             }
           ] =
             session.id
             |> persisted_messages()
             |> Enum.map(&Map.take(&1, [:role, :content]))
  end

  test "mcp tool integration registers wrapped HTTP tools and completes the agent loop", %{
    tool_registry: tool_registry
  } do
    caller = self()

    expect(ElixirClaw.MockHTTPClient, :list_tools, fn client_pid ->
      assert client_pid == caller

      {:ok,
       [
         %{
           name: "echo",
           description: "Echoes text",
           schema: %{
             "type" => "object",
             "properties" => %{"text" => %{"type" => "string"}},
             "required" => ["text"]
           }
         }
       ]}
    end)

    expect(ElixirClaw.MockHTTPClient, :call_tool, fn client_pid, "echo", %{"text" => "ping"} ->
      assert client_pid == caller
      {:ok, "pong"}
    end)

    assert {:ok, [_wrapper]} =
             ToolWrapper.register_mcp_tools(tool_registry, "demo-http", self(), :http)

    assert {:ok, session_id} = Manager.start_session(base_attrs(channel_user_id: "mcp-user"))
    assert :ok = MessageBus.subscribe("session:#{session_id}")

    expect(ElixirClaw.MockProvider, :chat, 2, fn messages, opts ->
      case Process.get(:mcp_round_trip_call, 0) do
        0 ->
          Process.put(:mcp_round_trip_call, 1)

          assert [
                   %{role: "system", content: _system_prompt},
                   %{role: "user", content: "<untrusted_user_input>call mcp</untrusted_user_input>"}
                 ] =
                   Enum.map(messages, &Map.take(&1, [:role, :content]))

          assert Enum.any?(Keyword.get(opts, :tools, []), fn tool ->
                   get_in(tool, [:function, :name]) == "mcp:demo-http:echo"
                 end)

          {:ok,
           %ProviderResponse{
             content: nil,
             tool_calls: [
               %ToolCall{
                 id: "mcp-call-1",
                 name: "mcp:demo-http:echo",
                 arguments: %{"text" => "ping"}
               }
             ],
             token_usage: %TokenUsage{input: 6, output: 2, total: 8}
           }}

        1 ->
          assert [
                   %{role: "system", content: _system_prompt},
                   %{role: "user", content: "<untrusted_user_input>call mcp</untrusted_user_input>"},
                   %{
                      role: "assistant",
                      content: "",
                     tool_calls: [
                       %ToolCall{
                         id: "mcp-call-1",
                         name: "mcp:demo-http:echo",
                         arguments: %{"text" => "ping"}
                       }
                     ]
                   },
                   %{
                     role: "tool",
                     tool_call_id: "mcp-call-1",
                     content: "<untrusted_tool_output>pong</untrusted_tool_output>"
                   }
                  ] =
                    Enum.map(
                      messages,
                     &Map.take(&1, [:role, :content, :tool_calls, :tool_call_id])
                   )

          {:ok,
           %ProviderResponse{
             content: "MCP complete",
             token_usage: %TokenUsage{input: 1, output: 4, total: 5}
           }}
      end
    end)

    assert {:ok, %ProviderResponse{content: "MCP complete"}} =
             Loop.process_message(session_id, "call mcp")

    assert_receive %{type: :outgoing_message, content: "MCP complete", session_id: ^session_id}
  end

  test "sensitive user input never appears in captured integration logs" do
    assert {:ok, session_id} = Manager.start_session(base_attrs(channel_user_id: "security-user"))

    secret_input = "api_key=sk-secret-123456789 Bearer abcdefghijklmnop"
    sanitized_input = ContextBuilder.sanitize_user_content(secret_input)

    expect(ElixirClaw.MockProvider, :chat, fn messages, _opts ->
      assert [
               %{role: "system", content: _system_prompt},
               %{role: "user", content: wrapped_input}
             ] =
               Enum.map(messages, &Map.take(&1, [:role, :content]))

      assert wrapped_input ==
               "<untrusted_user_input>#{sanitized_input}</untrusted_user_input>"

      {:ok,
       %ProviderResponse{
         content: "safe reply",
         token_usage: %TokenUsage{input: 9, output: 3, total: 12}
       }}
    end)

    assert {:ok, %ProviderResponse{content: "safe reply"}} =
             Loop.process_message(session_id, secret_input)

    persisted = Enum.map(persisted_messages(session_id), & &1.content) |> Enum.join("\n")
    SecurityHelpers.assert_no_secrets(persisted)
    refute persisted =~ "sk-"
    refute persisted =~ "Bearer "
    assert persisted =~ "safe reply"
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

  defp persisted_messages(session_id) do
    Repo.list_session_messages(session_id)
  end

  defp unique_cli_name do
    Module.concat([CLI, "Integration#{System.unique_integer([:positive])}"])
  end

  defp restore_loop_config(nil), do: Application.delete_env(:elixir_claw, Loop)
  defp restore_loop_config(config), do: Application.put_env(:elixir_claw, Loop, config)

  defp restore_env(key, nil), do: Application.delete_env(:elixir_claw, key)
  defp restore_env(key, value), do: Application.put_env(:elixir_claw, key, value)

  defp kill_session_processes do
    for pid <- Registry.select(ElixirClaw.SessionRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}]) do
      _ = DynamicSupervisor.terminate_child(ElixirClaw.SessionSupervisor, pid)
    end
  catch
    :exit, _reason -> :ok
  end

end

defmodule IntegrationMockToolAdapter do
  @behaviour ElixirClaw.Tool

  def name, do: "test_tool"
  def description, do: "Runs the integration mock tool"

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
