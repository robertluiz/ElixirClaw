defmodule ElixirClaw.Agent.CapabilityInventoryTest do
  use ExUnit.Case, async: false

  alias ElixirClaw.Agent.CapabilityInventory
  alias ElixirClaw.MCP.ToolWrapper
  alias ElixirClaw.Tools.Registry, as: ToolRegistry

  setup do
    registry_name = :capability_inventory_test_registry
    start_supervised!({ToolRegistry, name: registry_name})
    %{tool_registry: registry_name}
  end

  test "build/1 uses the metadata tool registry and groups runtime capabilities", %{
    tool_registry: tool_registry
  } do
    assert :ok = ToolRegistry.register(tool_registry, CapabilityInventoryBuiltinToolAdapter)
    assert :ok = ToolRegistry.register(tool_registry, ElixirClaw.Tools.RunTerminalCommand)

    assert :ok =
             ToolRegistry.register(tool_registry, %ToolWrapper{
               name: "echo",
               description: "Echo text",
               schema: %{"type" => "object"},
               client_type: :http,
               client_pid: self(),
               server_name: "demo-http"
             })

    inventory =
      CapabilityInventory.build(%{
        "channel" => "cli",
        "metadata" => %{
          "tool_registry" => tool_registry,
          "runtime_task_agents" => [
            %{
              "name" => "triage-helper",
              "description" => "triage",
              "system_prompt" => "Triage quickly.",
              "tasks" => ["Classify severity"]
            }
          ]
        }
      })

    assert "capability_inventory_builtin_tool" in inventory.tools
    assert "run_terminal_command" in inventory.tools
    assert "mcp:demo-http:echo" in inventory.tools
    assert "triage-helper" in inventory.agents

    assert Enum.any?(inventory.mcps, fn mcp ->
             mcp.name == "demo-http" and mcp.tools == ["mcp:demo-http:echo"]
           end)

    assert Enum.any?(inventory.mcps, fn mcp ->
             mcp.name == "local-terminal" and mcp.tools == ["run_terminal_command"]
           end)
  end

  test "build/1 respects active task agent MCP allowlists when listing capabilities", %{
    tool_registry: tool_registry
  } do
    assert :ok =
             ToolRegistry.register(tool_registry, %ToolWrapper{
               name: "echo",
               description: "Echo text",
               schema: %{"type" => "object"},
               client_type: :http,
               client_pid: self(),
               server_name: "demo-http"
             })

    assert :ok =
             ToolRegistry.register(tool_registry, %ToolWrapper{
               name: "ping",
               description: "Ping text",
               schema: %{"type" => "object"},
               client_type: :http,
               client_pid: self(),
               server_name: "demo-stdio"
             })

    inventory =
      CapabilityInventory.build(%{
        "channel" => "cli",
        "metadata" => %{
          "tool_registry" => tool_registry,
          "active_task_agent" => "restricted-agent",
          "runtime_task_agents" => [
            %{
              "name" => "restricted-agent",
              "description" => "Only allow one MCP",
              "system_prompt" => "Use the allowed MCP only.",
              "tasks" => ["Prefer approved MCP tools"],
              "mcp_servers" => ["demo-http"]
            }
          ]
        }
      })

    assert "mcp:demo-http:echo" in inventory.tools
    refute "mcp:demo-stdio:ping" in inventory.tools

    assert Enum.any?(inventory.mcps, &(&1.name == "demo-http"))
    refute Enum.any?(inventory.mcps, &(&1.name == "demo-stdio"))
  end

  test "build/1 and to_system_prompt/1 tolerate missing registries without crashing" do
    context = %{"metadata" => %{"tool_registry" => :missing_capability_inventory_registry}}

    inventory = CapabilityInventory.build(context)

    if Process.whereis(ToolRegistry) do
      assert is_list(inventory.tools)
      assert is_list(inventory.mcps)
    else
      assert inventory.tools == []
      assert inventory.mcps == []
    end

    prompt = CapabilityInventory.to_system_prompt(context)

    assert prompt =~ "Runtime capability inventory:"
    assert prompt =~ "Tools:"
    assert prompt =~ "MCPs:"
  end

  test "to_system_prompt/1 only mentions the virtual terminal MCP when terminal tools are available",
       %{
         tool_registry: tool_registry
       } do
    no_terminal_prompt =
      CapabilityInventory.to_system_prompt(%{
        "channel" => "cli",
        "metadata" => %{"tool_registry" => tool_registry}
      })

    refute no_terminal_prompt =~
             "Terminal access is also exposed as a virtual MCP named local-terminal"

    assert :ok = ToolRegistry.register(tool_registry, ElixirClaw.Tools.RunTerminalCommand)

    terminal_prompt =
      CapabilityInventory.to_system_prompt(%{
        "channel" => "cli",
        "metadata" => %{"tool_registry" => tool_registry}
      })

    assert terminal_prompt =~
             "Terminal access is also exposed as a virtual MCP named local-terminal"
  end
end

defmodule CapabilityInventoryBuiltinToolAdapter do
  @behaviour ElixirClaw.Tool

  def name, do: "capability_inventory_builtin_tool"
  def description, do: "Capability inventory built-in tool"
  def parameters_schema, do: %{"type" => "object", "properties" => %{}}
  def execute(_params, _context), do: {:ok, "ok"}
  def max_output_bytes, do: 65_536
  def timeout_ms, do: 100
end
