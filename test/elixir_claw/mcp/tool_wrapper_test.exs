defmodule ElixirClaw.MCP.ToolWrapperTest do
  use ExUnit.Case, async: false

  import Mox

  alias ElixirClaw.MCP.ToolWrapper
  alias ElixirClaw.Tools.Registry

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    Mox.set_mox_global()

    previous_http = Application.get_env(:elixir_claw, :mcp_http_client_module)
    previous_stdio = Application.get_env(:elixir_claw, :mcp_stdio_client_module)

    Application.put_env(:elixir_claw, :mcp_http_client_module, ElixirClaw.MockHTTPClient)
    Application.put_env(:elixir_claw, :mcp_stdio_client_module, ElixirClaw.MockStdioClient)

    on_exit(fn ->
      restore_env(:mcp_http_client_module, previous_http)
      restore_env(:mcp_stdio_client_module, previous_stdio)
    end)

    unless Process.whereis(ElixirClaw.ToolSupervisor) do
      start_supervised!({Task.Supervisor, name: ElixirClaw.ToolSupervisor})
    end

    start_supervised!({Registry, name: :test_mcp_registry})
    :ok
  end

  describe "tool metadata" do
    test "builds string-based tool names and defaults from MCP tool specs" do
      wrapper =
        %ToolWrapper{
          name: "echo",
          description: "Echo text",
          schema: %{"type" => "object", "required" => ["text"]},
          client_type: :http,
          client_pid: self(),
          server_name: "demo-server"
        }

      assert ToolWrapper.name(wrapper) == "mcp:demo-server:echo"
      assert ToolWrapper.description(wrapper) == "Echo text"
      assert ToolWrapper.parameters_schema(wrapper) == %{"type" => "object", "required" => ["text"]}
      assert ToolWrapper.timeout_ms(wrapper) == 30_000
      assert ToolWrapper.max_output_bytes(wrapper) == 65_536
    end

    test "respects configured timeout and output limits" do
      wrapper =
        %ToolWrapper{
          name: "echo",
          description: "Echo text",
          schema: %{},
          client_type: :http,
          client_pid: self(),
          server_name: "demo-server",
          timeout_ms: 45,
          max_output_bytes: 8
        }

      assert ToolWrapper.timeout_ms(wrapper) == 45
      assert ToolWrapper.max_output_bytes(wrapper) == 8
    end
  end

  describe "execute/3" do
    test "calls the HTTP MCP client and truncates oversized output" do
      wrapper =
        %ToolWrapper{
          name: "echo",
          description: "Echo text",
          schema: %{},
          client_type: :http,
          client_pid: self(),
          server_name: "demo-server",
          max_output_bytes: 5
        }

      expect(ElixirClaw.MockHTTPClient, :call_tool, fn pid, "echo", %{"text" => "hello"} ->
        assert pid == self()
        {:ok, "abcdefgh"}
      end)

      assert {:ok, "abcde[OUTPUT TRUNCATED at 64KB]"} =
               ToolWrapper.execute(wrapper, %{"text" => "hello"}, %{})
    end

    test "calls the stdio MCP client" do
      wrapper =
        %ToolWrapper{
          name: "sum",
          description: "Adds numbers",
          schema: %{},
          client_type: :stdio,
          client_pid: self(),
          server_name: "math-server"
        }

      expect(ElixirClaw.MockStdioClient, :call_tool, fn pid, "sum", %{"a" => 1, "b" => 2} ->
        assert pid == self()
        {:ok, "3"}
      end)

      assert {:ok, "3"} = ToolWrapper.execute(wrapper, %{"a" => 1, "b" => 2}, %{})
    end

    test "returns errors from the MCP client unchanged" do
      wrapper =
        %ToolWrapper{
          name: "echo",
          description: "Echo text",
          schema: %{},
          client_type: :http,
          client_pid: self(),
          server_name: "demo-server"
        }

      expect(ElixirClaw.MockHTTPClient, :call_tool, fn _pid, "echo", %{} ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = ToolWrapper.execute(wrapper, %{}, %{})
    end
  end

  describe "register_mcp_tools/4" do
    test "lists HTTP tools, registers wrappers, and bridges ToolRegistry.execute/4" do
      caller = self()

      expect(ElixirClaw.MockHTTPClient, :list_tools, fn client_pid ->
        assert client_pid == caller

        {:ok,
         [
           %{
             name: "echo",
             description: "Echo text",
             schema: %{"type" => "object", "required" => ["text"]}
           }
         ]}
      end)

      expect(ElixirClaw.MockHTTPClient, :call_tool, fn client_pid, "echo", %{"text" => "hello"} ->
        assert client_pid == caller
        {:ok, "hello"}
      end)

      assert {:ok, [wrapper]} =
               ToolWrapper.register_mcp_tools(
                 :test_mcp_registry,
                 "demo-server",
                 self(),
                 :http
               )

      assert ToolWrapper.name(wrapper) == "mcp:demo-server:echo"
      assert Registry.list(:test_mcp_registry) == ["mcp:demo-server:echo"]
      assert {:ok, ^wrapper} = Registry.get("mcp:demo-server:echo", :test_mcp_registry)

      assert {:ok, "hello"} =
               Registry.execute(
                 "mcp:demo-server:echo",
                 %{"text" => "hello"},
                 %{},
                 :test_mcp_registry
               )

      assert Registry.to_provider_format(:test_mcp_registry) == [
               %{
                 type: "function",
                 function: %{
                   name: "mcp:demo-server:echo",
                   description: "Echo text",
                   parameters: %{"type" => "object", "required" => ["text"]}
                 }
               }
             ]
    end

    test "supports stdio tools" do
      expect(ElixirClaw.MockStdioClient, :list_tools, fn client_pid ->
        assert client_pid == self()
        {:ok, [%{name: "sum", description: "Adds numbers", schema: %{"type" => "object"}}]}
      end)

      assert {:ok, [wrapper]} =
               ToolWrapper.register_mcp_tools(
                 :test_mcp_registry,
                 "math-server",
                 self(),
                 :stdio
               )

      assert ToolWrapper.name(wrapper) == "mcp:math-server:sum"
      assert Registry.list(:test_mcp_registry) == ["mcp:math-server:sum"]
    end

    test "returns errors and does not register tools when discovery fails" do
      expect(ElixirClaw.MockHTTPClient, :list_tools, fn _client_pid ->
        {:error, :disconnected}
      end)

      assert {:error, :disconnected} =
               ToolWrapper.register_mcp_tools(
                 :test_mcp_registry,
                 "demo-server",
                 self(),
                 :http
               )

      assert Registry.list(:test_mcp_registry) == []
    end
  end

  describe "unregister_mcp_tools/2" do
    test "removes only tools belonging to the given MCP server" do
      demo_wrapper =
        %ToolWrapper{
          name: "echo",
          description: "Echo text",
          schema: %{},
          client_type: :http,
          client_pid: self(),
          server_name: "demo-server"
        }

      other_wrapper =
        %ToolWrapper{
          name: "sum",
          description: "Adds numbers",
          schema: %{},
          client_type: :stdio,
          client_pid: self(),
          server_name: "math-server"
        }

      assert :ok = Registry.register(:test_mcp_registry, demo_wrapper)
      assert :ok = Registry.register(:test_mcp_registry, other_wrapper)

      assert :ok = ToolWrapper.unregister_mcp_tools(:test_mcp_registry, "demo-server")
      assert Registry.list(:test_mcp_registry) == ["mcp:math-server:sum"]
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:elixir_claw, key)
  defp restore_env(key, value), do: Application.put_env(:elixir_claw, key, value)
end
