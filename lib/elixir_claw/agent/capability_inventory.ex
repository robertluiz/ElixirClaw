defmodule ElixirClaw.Agent.CapabilityInventory do
  @moduledoc false

  alias ElixirClaw.Agent.TaskAgent
  alias ElixirClaw.Skills.Loader
  alias ElixirClaw.Tools.Registry, as: ToolRegistry

  @virtual_terminal_mcp %{
    name: "local-terminal",
    description:
      "Virtual local MCP-style capability for machine terminal access, including one-shot commands, interactive sessions, and TUI launchers.",
    tools: [
      "run_terminal_command",
      "launch_codex_tui",
      "launch_opencode_tui",
      "start_interactive_terminal_session",
      "send_interactive_terminal_input",
      "read_interactive_terminal_output",
      "stop_interactive_terminal_session"
    ]
  }

  @builtin_subagents [
    %{
      name: "feature-builder",
      description: "Implements features with TDD and incremental delivery."
    },
    %{name: "bug-fixer", description: "Diagnoses regressions and applies targeted fixes."},
    %{name: "test-writer", description: "Expands behavior-focused automated coverage."},
    %{name: "code-reviewer", description: "Reviews changes for correctness and maintainability."},
    %{name: "refactoring-mentor", description: "Improves structure while preserving behavior."}
  ]

  def build(context \\ %{}) do
    %{
      tools: tool_names(context),
      mcps: mcp_capabilities(context),
      skills: skill_names(),
      agents: task_agent_names(context),
      subagents: @builtin_subagents
    }
  end

  def to_system_prompt(context \\ %{}) do
    inventory = build(context)
    terminal_available? = Enum.any?(inventory.mcps, &(&1.name == "local-terminal"))

    [
      "Runtime capability inventory:",
      "Tools: #{join_or_none(inventory.tools)}",
      "MCPs: #{format_mcps(inventory.mcps)}",
      "Skills: #{join_or_none(inventory.skills)}",
      "Task agents: #{join_or_none(inventory.agents)}",
      "Built-in orchestration subagents: #{format_subagents(inventory.subagents)}",
      if(
        terminal_available?,
        do:
          "Terminal access is also exposed as a virtual MCP named local-terminal with session tools for start/send/read/stop and TUI launchers for Codex/OpenCode.",
        else: nil
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp tool_names(context) do
    metadata = Map.get(context, "metadata", Map.get(context, :metadata, %{}))
    registry = registry_from_metadata(metadata)

    cond do
      is_atom(registry) and Process.whereis(registry) ->
        ToolRegistry.list_context_tools(registry, context)

      Process.whereis(ToolRegistry) ->
        ToolRegistry.list_context_tools(context)

      true ->
        []
    end
    |> Enum.sort()
  end

  defp registry_from_metadata(metadata) when is_map(metadata) do
    Map.get(metadata, "tool_registry", Map.get(metadata, :tool_registry))
  end

  defp registry_from_metadata(_metadata), do: nil

  defp mcp_capabilities(context) do
    tool_names = tool_names(context)

    actual_mcps =
      tool_names
      |> Enum.filter(&String.starts_with?(&1, "mcp:"))
      |> Enum.group_by(fn name -> name |> String.split(":", parts: 3) |> Enum.at(1) end)
      |> Enum.map(fn {server_name, names} ->
        %{
          name: server_name,
          description: "Registered MCP server exposed through tool wrappers.",
          tools: Enum.sort(names)
        }
      end)

    terminal_tools = Enum.filter(tool_names, &(&1 in @virtual_terminal_mcp.tools))

    actual_mcps ++
      if terminal_tools == [] do
        []
      else
        [%{@virtual_terminal_mcp | tools: terminal_tools}]
      end
  end

  defp skill_names do
    Loader.load_skills_dirs(nil)
    |> Enum.flat_map(fn
      {:ok, skill} -> [skill.name]
      _other -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp task_agent_names(context) do
    runtime_agents =
      context
      |> Map.get("metadata", Map.get(context, :metadata, %{}))
      |> case do
        metadata when is_map(metadata) -> Map.get(metadata, "runtime_task_agents", [])
        _other -> []
      end

    TaskAgent.all(runtime_agents)
    |> Enum.map(& &1.name)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp join_or_none([]), do: "none"
  defp join_or_none(values), do: Enum.join(values, ", ")

  defp format_mcps([]), do: "none"

  defp format_mcps(mcps) do
    Enum.map_join(mcps, " | ", fn %{name: name, tools: tools} ->
      "#{name} [#{Enum.join(tools, ", ")}]"
    end)
  end

  defp format_subagents(subagents) do
    Enum.map_join(subagents, " | ", fn %{name: name, description: description} ->
      "#{name}: #{description}"
    end)
  end
end
