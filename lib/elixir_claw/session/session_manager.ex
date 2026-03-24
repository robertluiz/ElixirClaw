defmodule ElixirClaw.Session.Manager do
  @moduledoc false

  alias ElixirClaw.Repo
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
      :error -> {:error, :not_found}
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

    DynamicSupervisor.start_child(ElixirClaw.SessionSupervisor, {Worker, worker_opts})
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

      [] -> :error
    end
  end

  defp safe_call(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :not_found}
  end

  defp cleanup_session_record(session_id) do
    case Repo.get(SessionSchema, session_id) do
      nil -> :ok
      session ->
        _ = Repo.delete(session)
        :ok
    end
  end
end
