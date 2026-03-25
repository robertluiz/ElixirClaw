defmodule ElixirClaw.Agent.MemoryGraphIndexer do
  @moduledoc false

  use GenServer

  alias ElixirClaw.Agent.GraphMemory

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
  end

  def init(:ok), do: {:ok, %{}}

  def index_execution_async(session_id, attrs) when is_binary(session_id) and is_map(attrs) do
    GenServer.cast(__MODULE__, {:index_execution, session_id, attrs})
  end

  def list_indexed_nodes(session_id), do: GraphMemory.list_session_nodes(session_id)

  def handle_cast({:index_execution, session_id, attrs}, state) do
    _ = GraphMemory.record_execution(session_id, attrs)
    _ = GraphMemory.refresh_day_summary(session_id, token_budget: 300)
    _ = GraphMemory.refresh_session_summary(session_id, token_budget: 300)
    {:noreply, state}
  end
end
