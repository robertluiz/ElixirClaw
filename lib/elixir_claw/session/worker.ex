defmodule ElixirClaw.Session.Worker do
  @moduledoc false

  use GenServer

  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.Session, as: SessionSchema
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
       max_calls_per_minute: Keyword.get(opts, :max_calls_per_minute, @default_max_calls_per_minute),
       sandbox_owner: Keyword.get(opts, :sandbox_owner)
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
        %{state.session | token_count_in: updated_token_count.input, token_count_out: updated_token_count.output}

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

  def handle_call(:end_session, _from, state) do
    persist_token_count!(state.session.id, state.token_count)
    {:stop, :normal, :ok, state}
  end

  defp maybe_allow_sandbox(nil), do: :ok

  defp maybe_allow_sandbox(owner_pid) do
    if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) do
      _ = Ecto.Adapters.SQL.Sandbox.allow(Repo, owner_pid, self())
    end

    :ok
  end

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
end
