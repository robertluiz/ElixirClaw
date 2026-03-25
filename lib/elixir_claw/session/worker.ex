defmodule ElixirClaw.Session.Worker do
  @moduledoc false

  use GenServer

  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.Session, as: SessionSchema
  alias ElixirClaw.Agent.TaskAgent
  alias ElixirClaw.Types.{Session, TokenUsage}

  @default_max_calls_per_minute 60

  @type state :: %{
          session: Session.t(),
          messages: list(),
          token_count: TokenUsage.t(),
          provider_pid: pid() | nil,
          call_timestamps: [integer()],
          max_calls_per_minute: pos_integer(),
          sandbox_owner: pid() | nil
        }

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :session_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      shutdown: 5_000
    }
  end

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    GenServer.start_link(__MODULE__, opts, name: via_tuple(session_id))
  end

  def get_session(server), do: GenServer.call(server, :get_session)
  def record_call(server, token_usage), do: GenServer.call(server, {:record_call, token_usage})
  def approve_tools(server, tool_names), do: GenServer.call(server, {:approve_tools, tool_names})

  def request_tool_approval(server, tool_name),
    do: GenServer.call(server, {:request_tool_approval, tool_name})

  def set_task_agent(server, task_agent_name),
    do: GenServer.call(server, {:set_task_agent, task_agent_name})

  def clear_task_agent(server), do: GenServer.call(server, :clear_task_agent)
  def create_task_agent(server, attrs), do: GenServer.call(server, {:create_task_agent, attrs})

  def put_metadata(server, metadata_updates),
    do: GenServer.call(server, {:put_metadata, metadata_updates})

  def end_session(server), do: GenServer.call(server, :end_session)

  def via_tuple(session_id) do
    {:via, Registry, {ElixirClaw.SessionRegistry, session_id}}
  end

  @impl true
  def init(opts) do
    maybe_allow_sandbox(Keyword.get(opts, :sandbox_owner))

    session = Keyword.fetch!(opts, :session)

    {:ok,
     %{
       session: session,
       messages: Keyword.get(opts, :messages, []),
       token_count: Keyword.get(opts, :token_count, %TokenUsage{}),
       provider_pid: Keyword.get(opts, :provider_pid),
       call_timestamps: Keyword.get(opts, :call_timestamps, []),
       max_calls_per_minute:
         Keyword.get(opts, :max_calls_per_minute, @default_max_calls_per_minute),
       sandbox_owner: nil
     }}
  end

  @impl true
  def handle_call(:get_session, _from, state) do
    {:reply, {:ok, state.session}, state}
  end

  def handle_call({:record_call, %TokenUsage{} = token_usage}, _from, state) do
    current_timestamp = System.monotonic_time(:second)
    recent_timestamps = Enum.filter(state.call_timestamps, &(&1 > current_timestamp - 60))

    if length(recent_timestamps) >= state.max_calls_per_minute do
      {:reply, {:error, :rate_limited}, %{state | call_timestamps: recent_timestamps}}
    else
      updated_token_count = TokenUsage.add(state.token_count, token_usage)

      updated_session =
        %{
          state.session
          | token_count_in: updated_token_count.input,
            token_count_out: updated_token_count.output
        }

      persist_token_count!(updated_session.id, updated_token_count)

      updated_state = %{
        state
        | session: updated_session,
          token_count: updated_token_count,
          call_timestamps: [current_timestamp | recent_timestamps]
      }

      {:reply, :ok, updated_state}
    end
  end

  def handle_call({:approve_tools, tool_names}, _from, state) when is_list(tool_names) do
    approved_tools =
      state.session.metadata
      |> Map.get("approved_tools", [])
      |> Kernel.++(tool_names)
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.sort()

    pending_tool_approvals =
      state.session.metadata
      |> Map.get("pending_tool_approvals", [])
      |> List.wrap()
      |> Kernel.--(approved_tools)

    updated_metadata =
      (state.session.metadata || %{})
      |> Map.put("approved_tools", approved_tools)
      |> Map.put("pending_tool_approvals", pending_tool_approvals)

    updated_session = %{state.session | metadata: updated_metadata}

    persist_session_metadata!(updated_session.id, updated_metadata)

    {:reply, :ok, %{state | session: updated_session}}
  end

  def handle_call({:request_tool_approval, tool_name}, _from, state) when is_binary(tool_name) do
    pending_tool_approvals =
      state.session.metadata
      |> Map.get("pending_tool_approvals", [])
      |> List.wrap()
      |> Kernel.++([tool_name])
      |> Enum.uniq()
      |> Enum.sort()

    updated_metadata =
      Map.put(state.session.metadata || %{}, "pending_tool_approvals", pending_tool_approvals)

    updated_session = %{state.session | metadata: updated_metadata}

    persist_session_metadata!(updated_session.id, updated_metadata)

    {:reply, :ok, %{state | session: updated_session}}
  end

  def handle_call({:set_task_agent, task_agent_name}, _from, state)
      when is_binary(task_agent_name) do
    runtime_agents = Map.get(state.session.metadata || %{}, "runtime_task_agents", [])

    case TaskAgent.fetch(task_agent_name, runtime_agents) do
      {:ok, _task_agent} ->
        updated_metadata =
          Map.put(state.session.metadata || %{}, "active_task_agent", task_agent_name)

        updated_session = %{state.session | metadata: updated_metadata}

        persist_session_metadata!(updated_session.id, updated_metadata)

        {:reply, :ok, %{state | session: updated_session}}

      {:error, :unknown_task_agent} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:create_task_agent, attrs}, _from, state) when is_map(attrs) do
    task_agent = TaskAgent.build_runtime(attrs)

    runtime_agents =
      state.session.metadata
      |> Map.get("runtime_task_agents", [])
      |> Enum.reject(&(Map.get(&1, "name") == task_agent.name))
      |> Kernel.++([TaskAgent.to_metadata(task_agent)])

    updated_metadata =
      Map.put(state.session.metadata || %{}, "runtime_task_agents", runtime_agents)

    updated_session = %{state.session | metadata: updated_metadata}

    persist_session_metadata!(updated_session.id, updated_metadata)

    {:reply, {:ok, task_agent.name}, %{state | session: updated_session}}
  rescue
    error in ArgumentError ->
      {:reply, {:error, Exception.message(error)}, state}
  end

  def handle_call({:put_metadata, metadata_updates}, _from, state)
      when is_map(metadata_updates) do
    updated_metadata = Map.merge(state.session.metadata || %{}, metadata_updates)
    updated_session = %{state.session | metadata: updated_metadata}

    persist_session_metadata!(updated_session.id, updated_metadata)

    {:reply, :ok, %{state | session: updated_session}}
  end

  def handle_call(:clear_task_agent, _from, state) do
    updated_metadata = Map.delete(state.session.metadata || %{}, "active_task_agent")
    updated_session = %{state.session | metadata: updated_metadata}

    persist_session_metadata!(updated_session.id, updated_metadata)

    {:reply, :ok, %{state | session: updated_session}}
  end

  def handle_call(:end_session, _from, state) do
    persist_token_count!(state.session.id, state.token_count)
    {:stop, :normal, :ok, state}
  end

  defp maybe_allow_sandbox(nil), do: :ok

  defp maybe_allow_sandbox(_owner_pid), do: :ok

  defp persist_token_count!(session_id, %TokenUsage{} = token_count) do
    SessionSchema
    |> Repo.get!(session_id)
    |> SessionSchema.changeset(%{
      token_count_in: token_count.input,
      token_count_out: token_count.output
    })
    |> Repo.update!()

    :ok
  end

  defp persist_session_metadata!(session_id, metadata) when is_map(metadata) do
    SessionSchema
    |> Repo.get!(session_id)
    |> SessionSchema.changeset(%{metadata: metadata})
    |> Repo.update!()

    :ok
  end
end
