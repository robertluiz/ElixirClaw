defmodule ElixirClaw.Agent.TaskAgent do
  @moduledoc """
  Defines specialized task agents for common engineering workflows.
  """

  @enforce_keys [:name, :description, :system_prompt, :tasks]
  defstruct [:name, :description, :system_prompt, :tasks, :provider, :model, skills: [], mcp_servers: [], model_tier: :standard, source: :built_in]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          system_prompt: String.t(),
          tasks: [String.t()],
          provider: String.t() | nil,
          model: String.t() | nil,
          skills: [map()],
          mcp_servers: [String.t()],
          model_tier: :cheap | :standard | :powerful,
          source: :built_in | :configured | :runtime
        }

  @spec all() :: [t()]
  def all, do: all(nil)

  @spec fetch(String.t(), [map()] | nil) :: {:ok, t()} | {:error, :unknown_task_agent}
  def fetch(name, runtime_agents \\ nil) when is_binary(name) do
    normalized_name = String.trim(name)

    case Enum.find(all(runtime_agents), &(&1.name == normalized_name)) do
      %__MODULE__{} = task_agent -> {:ok, task_agent}
      nil -> {:error, :unknown_task_agent}
    end
  end

  @spec names([map()] | nil) :: [String.t()]
  def names(runtime_agents \\ nil), do: Enum.map(all(runtime_agents), & &1.name)

  @spec all([map()] | nil) :: [t()]
  def all(runtime_agents) when is_list(runtime_agents) do
    (Enum.map(runtime_agents, &from_runtime_config!/1) ++ configured_agents() ++ built_in_agents())
    |> Enum.uniq_by(& &1.name)
  end

  def all(nil) do
    (configured_agents() ++ built_in_agents())
    |> Enum.uniq_by(& &1.name)
  end

  @spec to_system_prompt(t()) :: String.t()
  def to_system_prompt(%__MODULE__{} = task_agent) do
    [
      "Specialized task agent: #{task_agent.name}",
      "Description: #{task_agent.description}",
      maybe_model_line(task_agent),
      "Mission: #{task_agent.system_prompt}",
      "Workflow tasks:",
      Enum.with_index(task_agent.tasks, 1)
      |> Enum.map_join("\n", fn {task, index} -> "#{index}. #{task}" end)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @spec configured_agents() :: [t()]
  def configured_agents do
    :elixir_claw
    |> Application.get_env(:task_agents, [])
    |> Enum.map(&from_config!/1)
  end

  @spec from_config!(map()) :: t()
  def from_config!(attrs) when is_map(attrs) do
    %__MODULE__{
      name: fetch_string!(attrs, "name", :name),
      description: fetch_string!(attrs, "description", :description),
      system_prompt: fetch_string!(attrs, "system_prompt", :system_prompt),
      tasks: fetch_tasks!(attrs),
      provider: fetch_optional_string(attrs, "provider", :provider),
      model: fetch_optional_string(attrs, "model", :model),
      skills: fetch_skills(attrs),
      mcp_servers: fetch_mcp_servers(attrs),
      model_tier: fetch_model_tier(attrs),
      source: :configured
    }
  end

  @spec build_runtime(map()) :: t()
  def build_runtime(attrs) when is_map(attrs) do
    from_runtime_config!(attrs)
  end

  @spec to_metadata(t()) :: map()
  def to_metadata(%__MODULE__{} = task_agent) do
    %{
      "name" => task_agent.name,
      "description" => task_agent.description,
      "system_prompt" => task_agent.system_prompt,
      "tasks" => task_agent.tasks,
      "provider" => task_agent.provider,
      "model" => task_agent.model,
      "skills" => task_agent.skills,
      "mcp_servers" => task_agent.mcp_servers,
      "model_tier" => Atom.to_string(task_agent.model_tier),
      "source" => Atom.to_string(task_agent.source)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp fetch_string!(attrs, string_key, atom_key) do
    value = Map.get(attrs, string_key) || Map.get(attrs, atom_key)

    case value do
      text when is_binary(text) ->
        trimmed = String.trim(text)
        if byte_size(trimmed) > 0, do: trimmed, else: raise(ArgumentError, "task agent #{string_key} must be a non-empty string")

      _invalid -> raise ArgumentError, "task agent #{string_key} must be a non-empty string"
    end
  end

  defp fetch_tasks!(attrs) do
    tasks = Map.get(attrs, "tasks") || Map.get(attrs, :tasks)

    case Enum.map(List.wrap(tasks), &normalize_task/1) |> Enum.reject(&is_nil/1) do
      [] -> raise ArgumentError, "task agent tasks must be a non-empty list of strings"
      normalized_tasks -> normalized_tasks
    end
  end

  defp normalize_task(task) when is_binary(task) do
    task = String.trim(task)
    if task == "", do: nil, else: task
  end

  defp normalize_task(_task), do: nil

  defp from_runtime_config!(attrs) do
    %__MODULE__{
      name: fetch_string!(attrs, "name", :name),
      description: fetch_string!(attrs, "description", :description),
      system_prompt: fetch_string!(attrs, "system_prompt", :system_prompt),
      tasks: fetch_tasks!(attrs),
      provider: fetch_optional_string(attrs, "provider", :provider),
      model: fetch_optional_string(attrs, "model", :model),
      skills: fetch_skills(attrs),
      mcp_servers: fetch_mcp_servers(attrs),
      model_tier: fetch_model_tier(attrs),
      source: :runtime
    }
  end

  defp fetch_skills(attrs) do
    attrs
    |> Map.get("skills", Map.get(attrs, :skills, []))
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_skill/1)
  end

  defp fetch_mcp_servers(attrs) do
    attrs
    |> Map.get("mcp_servers", Map.get(attrs, :mcp_servers, []))
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_skill(skill) do
    %{
      "name" => fetch_optional_string(skill, "name", :name),
      "content" => fetch_optional_string(skill, "content", :content),
      "token_estimate" => Map.get(skill, "token_estimate", Map.get(skill, :token_estimate, 0))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp fetch_optional_string(attrs, string_key, atom_key) do
    case Map.get(attrs, string_key) || Map.get(attrs, atom_key) do
      nil -> nil
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _other -> nil
    end
  end

  defp fetch_model_tier(attrs) do
    case fetch_optional_string(attrs, "model_tier", :model_tier) do
      "cheap" -> :cheap
      "powerful" -> :powerful
      _other -> :standard
    end
  end

  defp maybe_model_line(%__MODULE__{provider: provider, model: model, model_tier: model_tier})
       when is_binary(provider) and is_binary(model) do
    "Execution profile: provider=#{provider}, model=#{model}, tier=#{model_tier}"
  end

  defp maybe_model_line(%__MODULE__{model: model, model_tier: model_tier}) when is_binary(model) do
    "Execution profile: model=#{model}, tier=#{model_tier}"
  end

  defp maybe_model_line(_task_agent), do: nil

  defp built_in_agents do
    [
      %__MODULE__{
        name: "feature-builder",
        description: "Implements features with TDD, XP feedback loops, and incremental delivery.",
        system_prompt:
          "Drive feature delivery through small, verifiable steps. Prefer the simplest design that passes tests, preserve existing architecture boundaries, and keep the implementation focused on user-visible outcomes.",
        tasks: [
          "Write or update failing tests first",
          "Implement the smallest slice that makes the tests pass",
          "Refactor duplication while preserving behavior",
          "Verify the integrated workflow end-to-end"
        ]
      },
      %__MODULE__{
        name: "bug-fixer",
        description: "Diagnoses regressions, reproduces defects, and applies targeted fixes.",
        system_prompt:
          "Approach defects scientifically. Reproduce the failure, isolate the root cause, fix the smallest broken surface, and prove the regression is covered by tests before moving on.",
        tasks: [
          "Reproduce the defect with an automated check whenever possible",
          "Trace the root cause before editing production code",
          "Implement the minimal correction that preserves existing behavior",
          "Run focused regression verification after the fix"
        ]
      },
      %__MODULE__{
        name: "test-writer",
        description: "Expands fast, deterministic tests around behavior, regressions, and edge cases.",
        system_prompt:
          "Strengthen confidence with clear, behavior-focused tests. Prefer explicit assertions, cover happy paths and edge cases, and keep tests deterministic and readable.",
        tasks: [
          "Identify missing behavior coverage",
          "Add precise tests for happy path and boundary cases",
          "Keep fixtures and setup minimal",
          "Use failures to guide production changes only when necessary"
        ]
      },
      %__MODULE__{
        name: "code-reviewer",
        description: "Reviews changes for correctness, maintainability, and architectural fit.",
        system_prompt:
          "Evaluate code through the lenses of correctness, clarity, safety, and maintainability. Match existing conventions, highlight risky edges, and prefer concrete improvement guidance over vague commentary.",
        tasks: [
          "Inspect the change against surrounding patterns",
          "Call out correctness, safety, and readability risks",
          "Recommend the smallest high-value improvement",
          "Confirm verification evidence exists for the reviewed change"
        ]
      },
      %__MODULE__{
        name: "refactoring-mentor",
        description: "Improves structure while keeping behavior stable and tests green.",
        system_prompt:
          "Refactor for clarity and maintainability without changing observable behavior. Favor small moves, stable naming, and strong safety nets from tests.",
        tasks: [
          "Identify the specific design smell or maintenance pain",
          "Preserve behavior with existing or newly added tests",
          "Apply small structural improvements in sequence",
          "Re-run verification after each meaningful change"
        ]
      }
    ]
  end
end
