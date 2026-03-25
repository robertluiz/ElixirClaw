defmodule ElixirClaw.Agent.TaskAgentTest do
  use ExUnit.Case, async: false

  alias ElixirClaw.Agent.TaskAgent

  setup do
    previous_agents = Application.get_env(:elixir_claw, :task_agents)

    on_exit(fn ->
      if is_nil(previous_agents) do
        Application.delete_env(:elixir_claw, :task_agents)
      else
        Application.put_env(:elixir_claw, :task_agents, previous_agents)
      end
    end)

    :ok
  end

  describe "all/0" do
    test "returns built-in specialized agents for standard engineering tasks" do
      agent_names = TaskAgent.all() |> Enum.map(& &1.name)

      assert Enum.sort(agent_names) == [
               "bug-fixer",
               "code-reviewer",
               "feature-builder",
               "refactoring-mentor",
               "test-writer"
             ]
    end

    test "merges runtime configured task agents with built-ins" do
      Application.put_env(:elixir_claw, :task_agents, [
        %{
          "name" => "release-manager",
          "description" => "Prepare release notes and verification",
          "system_prompt" => "You are the release manager.",
          "tasks" => ["Confirm changelog", "Verify release checklist"]
        }
      ])

      assert {:ok, %TaskAgent{name: "release-manager", tasks: ["Confirm changelog", "Verify release checklist"]}} =
               TaskAgent.fetch("release-manager")
    end

    test "prefers runtime configured task agents over built-ins with the same name" do
      Application.put_env(:elixir_claw, :task_agents, [
        %{
          "name" => "bug-fixer",
          "description" => "Custom bug fixer",
          "system_prompt" => "Handle bugs with a custom workflow.",
          "tasks" => ["Collect logs first"]
        }
      ])

      assert {:ok, %TaskAgent{description: "Custom bug fixer", tasks: ["Collect logs first"]}} =
               TaskAgent.fetch("bug-fixer")
    end

    test "includes runtime session-defined task agents stored in metadata" do
      session_agents = [
        %{
          "name" => "triage-helper",
          "description" => "Handles first-pass triage",
          "system_prompt" => "Triage issues quickly.",
          "tasks" => ["Classify severity"],
          "provider" => "openai",
          "model" => "gpt-4o-mini",
          "model_tier" => "cheap"
        }
      ]

      assert {:ok,
              %TaskAgent{
                name: "triage-helper",
                provider: "openai",
                model: "gpt-4o-mini",
                model_tier: :cheap
              }} = TaskAgent.fetch("triage-helper", session_agents)
    end
  end

  describe "fetch/1" do
    test "returns an error for an unknown task agent" do
      assert {:error, :unknown_task_agent} = TaskAgent.fetch("unknown-agent")
    end

    test "formats a context prompt with mission and workflow tasks" do
      assert {:ok, task_agent} = TaskAgent.fetch("feature-builder")

      context_prompt = TaskAgent.to_system_prompt(task_agent)

      assert context_prompt =~ "Specialized task agent: feature-builder"
      assert context_prompt =~ "Mission:"
      assert context_prompt =~ "Workflow tasks:"
      assert context_prompt =~ "Write or update failing tests first"
    end

    test "builds a runtime-specialized agent from attrs with model selection metadata" do
      assert %TaskAgent{
               name: "release-sherpa",
               provider: "openai",
               model: "gpt-4o-mini",
               model_tier: :cheap,
               source: :runtime
             } =
               TaskAgent.build_runtime(%{
                 "name" => "release-sherpa",
                 "description" => "Coordinates release flow",
                 "system_prompt" => "Drive release verification.",
                 "tasks" => ["Validate changelog"],
                 "provider" => "openai",
                 "model" => "gpt-4o-mini",
                 "model_tier" => "cheap"
               })
    end
  end
end
