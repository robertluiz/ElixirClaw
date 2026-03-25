defmodule ElixirClaw.Tools.TaskAgentManagerTest do
  use ExUnit.Case, async: false

  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.Session, as: SessionSchema
  alias ElixirClaw.Session.Manager
  alias ElixirClaw.Tools.TaskAgentManager
  alias ElixirClaw.Types.Session

  setup do
    Repo.reset!()
    Repo.delete_all(SessionSchema)
    kill_session_processes()

    on_exit(fn -> kill_session_processes() end)

    :ok
  end

  test "creates and activates a runtime specialized agent through the tool" do
    assert {:ok, session_id} =
             Manager.start_session(base_attrs(channel_user_id: "tool-agent-user"))

    assert {:ok, result} =
             TaskAgentManager.execute(
               %{
                 "action" => "create",
                 "name" => "triage-helper",
                 "description" => "Handles first-pass issue triage",
                 "system_prompt" => "Triage bugs quickly and cheaply.",
                 "tasks" => ["Classify severity", "Recommend next step"],
                 "provider" => "openai",
                 "model" => "gpt-4o-mini",
                 "model_tier" => "cheap",
                 "activate" => true
               },
               %{"session_id" => session_id}
             )

    assert result =~ "triage-helper"
    assert result =~ "gpt-4o-mini"

    assert {:ok, %Session{} = session} = Manager.get_session(session_id)
    assert session.metadata["active_task_agent"] == "triage-helper"
    assert [%{"name" => "triage-helper"}] = session.metadata["runtime_task_agents"]
  end

  test "stores skills and mcp server bindings on a runtime specialized agent" do
    assert {:ok, session_id} =
             Manager.start_session(base_attrs(channel_user_id: "tool-agent-capabilities"))

    assert {:ok, _result} =
             TaskAgentManager.execute(
               %{
                 "action" => "create",
                 "name" => "docs-helper",
                 "description" => "Reads docs with attached capabilities",
                 "system_prompt" => "Use docs and loaded skills.",
                 "tasks" => ["Search docs"],
                 "skills" => [
                   %{
                     "name" => "docs-skill",
                     "content" => "Prefer official docs snippets.",
                     "token_estimate" => 8
                   }
                 ],
                 "mcp_servers" => ["docs"],
                 "activate" => true
               },
               %{"session_id" => session_id}
             )

    assert {:ok, %Session{} = session} = Manager.get_session(session_id)

    assert [
             %{
               "name" => "docs-helper",
               "mcp_servers" => ["docs"],
               "skills" => [%{"name" => "docs-skill"}]
             }
           ] = session.metadata["runtime_task_agents"]
  end

  test "recommends a cheap runtime task agent profile for trivial work" do
    assert {:ok, recommendation} =
             TaskAgentManager.execute(
               %{
                 "action" => "recommend",
                 "goal" => "rename a variable in one file",
                 "complexity" => "trivial"
               },
               %{"session_id" => "session-1"}
             )

    assert recommendation =~ "cheap"
    assert recommendation =~ "gpt-4o-mini"
  end

  test "recommends a powerful runtime task agent profile for complex work" do
    assert {:ok, recommendation} =
             TaskAgentManager.execute(
               %{
                 "action" => "recommend",
                 "goal" => "refactor a multi-step agent orchestration system",
                 "complexity" => "complex",
                 "needs_mcp" => true,
                 "needs_skills" => true
               },
               %{"session_id" => "session-1"}
             )

    assert recommendation =~ "powerful"
    assert recommendation =~ "gpt-4o"
    assert recommendation =~ "Attach skills: yes"
    assert recommendation =~ "Attach MCPs: yes"
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

  defp kill_session_processes do
    for pid <- Registry.select(ElixirClaw.SessionRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}]) do
      _ = DynamicSupervisor.terminate_child(ElixirClaw.SessionSupervisor, pid)
    end
  catch
    :exit, _reason -> :ok
  end
end
