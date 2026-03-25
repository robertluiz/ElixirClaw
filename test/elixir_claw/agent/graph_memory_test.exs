defmodule ElixirClaw.Agent.GraphMemoryTest do
  use ExUnit.Case, async: false

  alias ElixirClaw.Agent.GraphMemory
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

  describe "upsert_memory_node/1" do
    test "persists orchestrator graph nodes for style and executions" do
      session = Factory.insert_session!(channel_user_id: "graph-user")

      assert {:ok, %GraphNode{node_type: "style", scope: "global"}} =
               GraphMemory.upsert_memory_node(%{
                 session_id: session.id,
                 node_type: "style",
                 scope: "global",
                 name: "response-style",
                 content: "Use concise and direct answers.",
                 metadata: %{"source" => "user"}
               })

      assert {:ok, %GraphNode{node_type: "execution", scope: "session"}} =
               GraphMemory.upsert_memory_node(%{
                 session_id: session.id,
                 node_type: "execution",
                 scope: "session",
                 name: "tool-run",
                 content: "Executed manage_task_agent for triage-helper.",
                 metadata: %{"tool" => "manage_task_agent"}
               })

      assert [%GraphNode{node_type: "style"}, %GraphNode{node_type: "execution"}] =
               GraphMemory.list_session_nodes(session.id)
    end
  end

  describe "upsert_memory_edge/1" do
    test "persists typed edges between related memory nodes" do
      session = Factory.insert_session!()

      {:ok, source} =
        GraphMemory.upsert_memory_node(%{
          session_id: session.id,
          node_type: "episodic",
          scope: "session",
          name: "session-episode",
          content: "User requested concise output."
        })

      {:ok, target} =
        GraphMemory.upsert_memory_node(%{
          session_id: session.id,
          node_type: "preference",
          scope: "user",
          name: "verbosity-preference",
          content: "Prefers concise output."
        })

      assert {:ok, %GraphEdge{relation_type: "derived_from"}} =
               GraphMemory.upsert_memory_edge(%{
                 session_id: session.id,
                 source_node_id: target.id,
                 target_node_id: source.id,
                 relation_type: "derived_from",
                 metadata: %{"confidence" => 0.9}
               })

      target_id = target.id
      source_id = source.id

      assert [%GraphEdge{source_node_id: ^target_id, target_node_id: ^source_id}] =
               GraphMemory.list_session_edges(session.id)
    end
  end

  describe "record_execution/2" do
    test "stores an execution node plus temporal edge to the active day summary" do
      session = Factory.insert_session!()

      {:ok, day_summary} =
        GraphMemory.upsert_memory_node(%{
          session_id: session.id,
          node_type: "day_summary",
          scope: "day",
          name: "daily-summary",
          content: "Worked on orchestrator agent improvements today."
        })

      assert {:ok, %GraphNode{node_type: "execution", name: "manage_task_agent"} = execution_node} =
               GraphMemory.record_execution(session.id, %{
                 name: "manage_task_agent",
                 content: "Created triage-helper with cheap model.",
                 metadata: %{"result" => "ok"}
               })

      assert Enum.any?(GraphMemory.list_session_edges(session.id), fn edge ->
               edge.source_node_id == day_summary.id and edge.target_node_id == execution_node.id and
                 edge.relation_type == "temporal"
             end)
    end
  end

  describe "refresh_day_summary/1" do
    test "creates a day summary node from indexed executions" do
      session = Factory.insert_session!()

      assert {:ok, _node} =
               GraphMemory.record_execution(session.id, %{
                 name: "manage_task_agent",
                 content: "Created triage-helper with cheap model.",
                 metadata: %{"result" => "ok"}
               })

      assert {:ok, %GraphNode{node_type: "day_summary", content: content}} =
               GraphMemory.refresh_day_summary(session.id, token_budget: 200)

      assert content =~ "Created triage-helper with cheap model."
    end
  end

  describe "orchestrator_memory_summary/2" do
    test "returns a compact graph-backed memory summary for context injection" do
      session = Factory.insert_session!(channel_user_id: "summary-user")

      for attrs <- [
            %{node_type: "style", scope: "global", name: "response-style", content: "Use concise and direct answers."},
            %{node_type: "personality", scope: "global", name: "personality", content: "Act like a decisive senior engineer."},
            %{node_type: "preference", scope: "user", name: "language", content: "The user prefers pt-BR."},
            %{node_type: "day_summary", scope: "day", name: "daily-summary", content: "Today focused on dynamic orchestrator agents and memory design."}
          ] do
        {:ok, _node} = GraphMemory.upsert_memory_node(Map.put(attrs, :session_id, session.id))
      end

      assert {:ok, summary} = GraphMemory.orchestrator_memory_summary(session.id, token_budget: 200)
      assert summary =~ "Use concise and direct answers."
      assert summary =~ "Act like a decisive senior engineer."
      assert summary =~ "The user prefers pt-BR."
      assert summary =~ "Today focused on dynamic orchestrator agents and memory design."
    end
  end
end
