defmodule ElixirClaw.SessionTest do
  use ExUnit.Case, async: false

  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.Session, as: SessionSchema
  alias ElixirClaw.Session.Manager
  alias ElixirClaw.Types.{Session, TokenUsage}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    create_test_tables!()
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
