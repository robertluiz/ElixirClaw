defmodule ElixirClaw.Tools.TaskAgentManager do
  @moduledoc false

  @behaviour ElixirClaw.Tool

  alias ElixirClaw.Session.Manager

  @impl true
  def name, do: "manage_task_agent"

  @impl true
  def description do
    "Create, activate, deactivate, and inspect specialized task agents for the current session. Use this when the user requests a new specialized agent or when a cheaper/stronger model profile is needed for a task."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ["create", "activate", "deactivate", "recommend"]},
        "name" => %{"type" => "string"},
        "description" => %{"type" => "string"},
        "system_prompt" => %{"type" => "string"},
        "tasks" => %{"type" => "array", "items" => %{"type" => "string"}},
        "provider" => %{"type" => "string"},
        "model" => %{"type" => "string"},
        "model_tier" => %{"type" => "string", "enum" => ["cheap", "standard", "powerful"]},
        "activate" => %{"type" => "boolean"},
        "goal" => %{"type" => "string"},
        "complexity" => %{"type" => "string", "enum" => ["trivial", "standard", "complex"]},
        "needs_skills" => %{"type" => "boolean"},
        "needs_mcp" => %{"type" => "boolean"}
      },
      "required" => ["action"]
    }
  end

  @impl true
  def execute(%{"action" => "create"} = params, %{"session_id" => session_id}) when is_binary(session_id) do
    with {:ok, agent_name} <- Manager.create_task_agent(session_id, params),
         :ok <- maybe_activate(params, session_id, agent_name) do
      {:ok,
       "Created task agent #{agent_name} with model #{Map.get(params, "model", "session-default")} and provider #{Map.get(params, "provider", "session-default")}."}
    end
  end

  def execute(%{"action" => "activate", "name" => name}, %{"session_id" => session_id})
      when is_binary(session_id) do
    case Manager.set_task_agent(session_id, name) do
      :ok -> {:ok, "Activated task agent #{name}."}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(%{"action" => "deactivate"}, %{"session_id" => session_id}) when is_binary(session_id) do
    case Manager.clear_task_agent(session_id) do
      :ok -> {:ok, "Deactivated the current task agent."}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(%{"action" => "recommend"} = params, _context) do
    {:ok, format_recommendation(recommend_profile(params))}
  end

  def execute(_params, _context), do: {:error, :invalid_params}

  @impl true
  def max_output_bytes, do: 16_384

  @impl true
  def timeout_ms, do: 1_000

  defp maybe_activate(%{"activate" => true}, session_id, agent_name), do: Manager.set_task_agent(session_id, agent_name)
  defp maybe_activate(_params, _session_id, _agent_name), do: :ok

  defp recommend_profile(params) do
    complexity = Map.get(params, "complexity", "standard")
    needs_skills = Map.get(params, "needs_skills", false)
    needs_mcp = Map.get(params, "needs_mcp", false)

    case complexity do
      "trivial" -> %{tier: "cheap", model: "gpt-4o-mini", attach_skills: false, attach_mcps: false}
      "complex" -> %{tier: "powerful", model: "gpt-4o", attach_skills: needs_skills or true, attach_mcps: needs_mcp or true}
      _other -> %{tier: "standard", model: "gpt-4o-mini", attach_skills: needs_skills, attach_mcps: needs_mcp}
    end
  end

  defp format_recommendation(profile) do
    [
      "Recommended task-agent profile:",
      "Tier: #{profile.tier}",
      "Model: #{profile.model}",
      "Attach skills: #{yes_no(profile.attach_skills)}",
      "Attach MCPs: #{yes_no(profile.attach_mcps)}"
    ]
    |> Enum.join("\n")
  end

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"
end
