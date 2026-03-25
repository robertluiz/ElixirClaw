defmodule ElixirClaw.SessionTest do
  use ExUnit.Case, async: false

  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.Session, as: SessionSchema
  alias ElixirClaw.Session.Manager
  alias ElixirClaw.Types.{Session, TokenUsage}

  setup do
    Repo.reset!()
    Repo.delete_all(ElixirClaw.Schema.Message)
    Repo.delete_all(SessionSchema)
    kill_session_processes()
    :ok
  end

  describe "start_session/1 and get_session/1" do
    test "starts a worker, registers it, and persists the session" do
      attrs = base_attrs(channel_user_id: "start-user")

      assert {:ok, session_id} = Manager.start_session(attrs)
      assert is_binary(session_id)

      assert {:ok, %Session{} = session} = Manager.get_session(session_id)
      assert session.id == session_id
      assert session.channel == "cli"
      assert session.channel_user_id == "start-user"
      assert session.provider == "openai"
      assert session.metadata == %{"locale" => "en"}

      persisted = Repo.get!(SessionSchema, session_id)
      assert persisted.channel == "cli"
      assert persisted.channel_user_id == "start-user"
      assert persisted.provider == "openai"
      assert persisted.metadata == %{"locale" => "en"}
    end

    test "returns not_found for an unknown session id" do
      assert {:error, :not_found} = Manager.get_session("missing-session")
    end
  end

  describe "list_sessions/0" do
    test "returns active session ids from the registry" do
      assert {:ok, first_id} = Manager.start_session(base_attrs(channel_user_id: "list-a"))
      assert {:ok, second_id} = Manager.start_session(base_attrs(channel_user_id: "list-b"))

      session_ids = Manager.list_sessions()

      assert Enum.sort(session_ids) == Enum.sort([first_id, second_id])
    end
  end

  describe "end_session/1" do
    test "terminates the worker and removes the registry entry" do
      assert {:ok, session_id} = Manager.start_session(base_attrs(channel_user_id: "end-user"))

      assert :ok = Manager.end_session(session_id)
      assert {:error, :not_found} = Manager.get_session(session_id)

      persisted = Repo.get!(SessionSchema, session_id)
      assert persisted.channel_user_id == "end-user"
    end
  end

  describe "record_call/2" do
    test "accumulates token usage in memory and persists it" do
      assert {:ok, session_id} = Manager.start_session(base_attrs(channel_user_id: "token-user"))

      assert :ok = Manager.record_call(session_id, %TokenUsage{input: 10, output: 20, total: 30})
      assert :ok = Manager.record_call(session_id, %TokenUsage{input: 3, output: 7, total: 10})

      assert {:ok, %Session{} = session} = Manager.get_session(session_id)
      assert session.token_count_in == 13
      assert session.token_count_out == 27

      persisted = Repo.get!(SessionSchema, session_id)
      assert persisted.token_count_in == 13
      assert persisted.token_count_out == 27
    end

    test "returns rate_limited when calls exceed the configured limit" do
      attrs = base_attrs(channel_user_id: "rate-user", max_calls_per_minute: 2)
      usage = %TokenUsage{input: 1, output: 1, total: 2}

      assert {:ok, session_id} = Manager.start_session(attrs)
      assert :ok = Manager.record_call(session_id, usage)
      assert :ok = Manager.record_call(session_id, usage)
      assert {:error, :rate_limited} = Manager.record_call(session_id, usage)

      persisted = Repo.get!(SessionSchema, session_id)
      assert persisted.token_count_in == 2
      assert persisted.token_count_out == 2
    end
  end

  describe "approve_tools/2" do
    test "persists explicit approvals in session metadata" do
      assert {:ok, session_id} =
               Manager.start_session(base_attrs(channel_user_id: "approval-user", metadata: %{"locale" => "en"}))

      assert :ok = Manager.approve_tools(session_id, ["privileged_tool", "bash"])

      assert {:ok, %Session{} = session} = Manager.get_session(session_id)
      assert session.metadata["approved_tools"] == ["bash", "privileged_tool"]

      persisted = Repo.get!(SessionSchema, session_id)
      assert persisted.metadata["approved_tools"] == ["bash", "privileged_tool"]
    end
  end

  describe "set_task_agent/2 and clear_task_agent/1" do
    test "persists the active specialized task agent in session metadata" do
      assert {:ok, session_id} =
               Manager.start_session(base_attrs(channel_user_id: "task-agent-user", metadata: %{"locale" => "en"}))

      assert :ok = Manager.set_task_agent(session_id, "feature-builder")

      assert {:ok, %Session{} = session} = Manager.get_session(session_id)
      assert session.metadata["active_task_agent"] == "feature-builder"

      persisted = Repo.get!(SessionSchema, session_id)
      assert persisted.metadata["active_task_agent"] == "feature-builder"

      assert :ok = Manager.clear_task_agent(session_id)
      assert {:ok, %Session{} = updated_session} = Manager.get_session(session_id)
      refute Map.has_key?(updated_session.metadata, "active_task_agent")
    end

    test "returns unknown_task_agent when the requested specialized agent is missing" do
      assert {:ok, session_id} = Manager.start_session(base_attrs(channel_user_id: "missing-task-agent"))

      assert {:error, :unknown_task_agent} = Manager.set_task_agent(session_id, "does-not-exist")
    end

    test "creates a runtime task agent and stores it in session metadata" do
      assert {:ok, session_id} = Manager.start_session(base_attrs(channel_user_id: "runtime-agent-user"))

      assert {:ok, "triage-helper"} =
               Manager.create_task_agent(session_id, %{
                 "name" => "triage-helper",
                 "description" => "Handles first-pass issue triage",
                 "system_prompt" => "Triage bugs quickly and cheaply.",
                 "tasks" => ["Classify severity", "Recommend next step"],
                 "provider" => "openai",
                 "model" => "gpt-4o-mini",
                 "model_tier" => "cheap"
               })

      assert {:ok, %Session{} = session} = Manager.get_session(session_id)

      assert [runtime_agent] = session.metadata["runtime_task_agents"]
      assert runtime_agent["name"] == "triage-helper"
      assert runtime_agent["model"] == "gpt-4o-mini"
      assert runtime_agent["model_tier"] == "cheap"
    end
  end

  describe "start_session/1 seeds orchestrator memory" do
    test "stores style, personality, and preference nodes from session metadata" do
      assert {:ok, session_id} =
               Manager.start_session(
                 base_attrs(
                   channel_user_id: "memory-user",
                   metadata: %{
                     "locale" => "pt-BR",
                     "response_style" => "Use concise answers.",
                     "orchestrator_personality" => "Act like a senior Elixir engineer."
                   }
                 )
               )

      Process.sleep(75)

      contents =
        ElixirClaw.Agent.GraphMemory.list_session_nodes(session_id)
        |> Enum.map(& &1.content)

      assert "The user prefers pt-BR." in contents
      assert "Use concise answers." in contents
      assert "Act like a senior Elixir engineer." in contents
    end
  end

  describe "worker isolation" do
    test "crashing one session worker does not affect another session" do
      assert {:ok, first_id} = Manager.start_session(base_attrs(channel_user_id: "crash-a"))
      assert {:ok, second_id} = Manager.start_session(base_attrs(channel_user_id: "crash-b"))

      [first_pid] = lookup_session_pids(first_id)
      assert Process.alive?(first_pid)

      Process.exit(first_pid, :boom)
      wait_until(fn -> not Process.alive?(first_pid) end)

      assert {:ok, %Session{id: ^second_id}} = Manager.get_session(second_id)
      assert :ok = Manager.record_call(second_id, %TokenUsage{input: 5, output: 8, total: 13})

      persisted = Repo.get!(SessionSchema, second_id)
      assert persisted.token_count_in == 5
      assert persisted.token_count_out == 8
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

  defp lookup_session_pids(session_id) do
    ElixirClaw.SessionRegistry
    |> Registry.lookup(session_id)
    |> Enum.map(fn {pid, _value} -> pid end)
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition was not met in time")

  defp kill_session_processes do
    for pid <- Registry.select(ElixirClaw.SessionRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}]) do
      _ = DynamicSupervisor.terminate_child(ElixirClaw.SessionSupervisor, pid)
    end
  catch
    :exit, _reason -> :ok
  end

end
