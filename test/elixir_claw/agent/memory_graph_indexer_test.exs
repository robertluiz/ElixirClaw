defmodule ElixirClaw.Agent.MemoryGraphIndexerTest do
  use ExUnit.Case, async: false

  alias ElixirClaw.Agent.MemoryGraphIndexer
  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.{GraphEdge, GraphNode, Message, Session}
  alias ElixirClaw.Test.Factory

  setup do
    Repo.reset!()
    Repo.delete_all(Message)
    Repo.delete_all(GraphEdge)
    Repo.delete_all(GraphNode)
    Repo.delete_all(Session)
    :ok
  end

  test "indexes persisted tool executions asynchronously into graph memory" do
    session = Factory.insert_session!()

    assert :ok =
             MemoryGraphIndexer.index_execution_async(session.id, %{
               name: "manage_task_agent",
               content: "Created docs-helper and activated it.",
               metadata: %{"tool_call_id" => "call-1"}
             })

    Process.sleep(75)

    assert Enum.any?(MemoryGraphIndexer.list_indexed_nodes(session.id), fn node ->
             node.node_type == "execution" and node.name == "manage_task_agent"
           end)

    assert Enum.any?(MemoryGraphIndexer.list_indexed_nodes(session.id), fn node ->
             node.node_type == "day_summary"
           end)
  end
end
