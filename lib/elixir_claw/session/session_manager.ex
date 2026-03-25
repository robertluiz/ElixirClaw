defmodule ElixirClaw.Session.Manager do
  @moduledoc false

  alias ElixirClaw.Repo
  alias ElixirClaw.Agent.TaskAgent
  alias ElixirClaw.Schema.Session, as: SessionSchema
  alias ElixirClaw.Session.Worker
  alias ElixirClaw.Types.{Session, TokenUsage}

  @default_max_calls_per_minute 60

  @spec start_session(map()) :: {:ok, String.t()} | {:error, term()}
  def start_session(attrs) when is_map(attrs) do
    session_id = Ecto.UUID.generate()
    schema_attrs = schema_attrs(attrs)

    with {:ok, persisted_session} <- create_session_record(session_id, schema_attrs),
         {:ok, _pid} <- start_session_worker(persisted_session, attrs) do
      {:ok, persisted_session.id}
    else
      {:error, reason} = error ->
        cleanup_session_record(session_id)

        case reason do
          %Ecto.Changeset{} -> error
          _ -> {:error, reason}
        end
    end
  end

  @spec get_session(String.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def get_session(session_id) do
    case lookup_pid(session_id) do
      {:ok, pid} ->
        safe_call(fn -> Worker.get_session(pid) end)

      :error ->
        {:error, :not_found}
    end
  end

  @spec list_sessions() :: [String.t()]
  def list_sessions do
    Registry.select(ElixirClaw.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @spec end_session(String.t()) :: :ok
  def end_session(session_id) do
    case lookup_pid(session_id) do
      {:ok, pid} ->
        _ = safe_call(fn -> Worker.end_session(pid) end)
        :ok

      :error ->
        :ok
    end
  end

  @spec record_call(String.t(), TokenUsage.t()) :: :ok | {:error, :not_found | :rate_limited}
  def record_call(session_id, %TokenUsage{} = token_usage) do
    case lookup_pid(session_id) do
      {:ok, pid} -> safe_call(fn -> Worker.record_call(pid, token_usage) end)
      :error -> {:error, :not_found}
    end
  end

  @spec approve_tools(String.t(), [String.t()]) :: :ok | {:error, :not_found}
  def approve_tools(session_id, tool_names) when is_binary(session_id) and is_list(tool_names) do
    case lookup_pid(session_id) do
      {:ok, pid} -> safe_call(fn -> Worker.approve_tools(pid, tool_names) end)
      :error -> {:error, :not_found}
    end
  end

  @spec request_tool_approval(String.t(), String.t()) :: :ok | {:error, :not_found}
  def request_tool_approval(session_id, tool_name)
      when is_binary(session_id) and is_binary(tool_name) do
    case lookup_pid(session_id) do
      {:ok, pid} -> safe_call(fn -> Worker.request_tool_approval(pid, tool_name) end)
      :error -> {:error, :not_found}
    end
  end

  @spec set_task_agent(String.t(), String.t()) :: :ok | {:error, :not_found | :unknown_task_agent}
  def set_task_agent(session_id, task_agent_name)
      when is_binary(session_id) and is_binary(task_agent_name) do
    case lookup_pid(session_id) do
      {:ok, pid} -> safe_call(fn -> Worker.set_task_agent(pid, task_agent_name) end)
      :error -> {:error, :not_found}
    end
  end

  @spec clear_task_agent(String.t()) :: :ok | {:error, :not_found}
  def clear_task_agent(session_id) when is_binary(session_id) do
    case lookup_pid(session_id) do
      {:ok, pid} -> safe_call(fn -> Worker.clear_task_agent(pid) end)
      :error -> {:error, :not_found}
    end
  end

  @spec create_task_agent(String.t(), map()) :: {:ok, String.t()} | {:error, :not_found | term()}
  def create_task_agent(session_id, attrs) when is_binary(session_id) and is_map(attrs) do
    case lookup_pid(session_id) do
      {:ok, pid} -> safe_call(fn -> Worker.create_task_agent(pid, attrs) end)
      :error -> {:error, :not_found}
    end
  end

  @spec put_metadata(String.t(), map()) :: :ok | {:error, :not_found}
  def put_metadata(session_id, metadata_updates)
      when is_binary(session_id) and is_map(metadata_updates) do
    case lookup_pid(session_id) do
      {:ok, pid} -> safe_call(fn -> Worker.put_metadata(pid, metadata_updates) end)
      :error -> {:error, :not_found}
    end
  end

  @spec effective_task_agent(Session.t()) :: {:ok, TaskAgent.t()} | {:error, :unknown_task_agent}
  def effective_task_agent(%Session{metadata: metadata}) when is_map(metadata) do
    TaskAgent.fetch(
      Map.get(metadata, "active_task_agent", ""),
      Map.get(metadata, "runtime_task_agents", [])
    )
  end

  def effective_task_agent(_session), do: {:error, :unknown_task_agent}

  defp create_session_record(session_id, attrs) do
    %SessionSchema{id: session_id}
    |> SessionSchema.changeset(attrs)
    |> Repo.insert()
  end

  defp start_session_worker(%SessionSchema{} = persisted_session, attrs) do
    worker_opts = [
      session_id: persisted_session.id,
      session: to_types_session(persisted_session),
      token_count: %TokenUsage{
        input: persisted_session.token_count_in,
        output: persisted_session.token_count_out,
        total: persisted_session.token_count_in + persisted_session.token_count_out
      },
      sandbox_owner: self(),
      max_calls_per_minute: max_calls_per_minute(attrs)
    ]

    with {:ok, _pid} = result <-
           DynamicSupervisor.start_child(ElixirClaw.SessionSupervisor, {Worker, worker_opts}) do
      :ok =
        ElixirClaw.Agent.GraphMemory.seed_session_memory(
          persisted_session.id,
          persisted_session.metadata || %{}
        )

      _ =
        ElixirClaw.Agent.GraphMemory.refresh_session_summary(persisted_session.id,
          token_budget: 300
        )

      result
    end
  end

  defp schema_attrs(attrs) do
    %{
      channel: fetch_attr(attrs, :channel),
      channel_user_id: fetch_attr(attrs, :channel_user_id),
      provider: fetch_attr(attrs, :provider),
      model: fetch_attr(attrs, :model),
      metadata: fetch_attr(attrs, :metadata, %{})
    }
  end

  defp to_types_session(%SessionSchema{} = session) do
    %Session{
      id: session.id,
      channel: session.channel,
      channel_user_id: session.channel_user_id,
      provider: session.provider,
      model: session.model,
      messages: [],
      token_count_in: session.token_count_in,
      token_count_out: session.token_count_out,
      metadata: session.metadata || %{},
      created_at: session.inserted_at
    }
  end

  defp fetch_attr(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp max_calls_per_minute(attrs) do
    fetch_attr(attrs, :max_calls_per_minute, @default_max_calls_per_minute)
  end

  defp lookup_pid(session_id) do
    case Registry.lookup(ElixirClaw.SessionRegistry, session_id) do
      [{pid, _value}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: :error

      [] ->
        :error
    end
  end

  defp safe_call(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :not_found}
  end

  defp cleanup_session_record(session_id) do
    case Repo.get(SessionSchema, session_id) do
      nil ->
        :ok

      session ->
        _ = Repo.delete(session)
        :ok
    end
  end
end
