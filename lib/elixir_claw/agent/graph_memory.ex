defmodule ElixirClaw.Agent.GraphMemory do
  @moduledoc false

  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.{GraphEdge, GraphNode}

  def upsert_memory_node(attrs) when is_map(attrs) do
    attrs
    |> normalize_node_attrs()
    |> then(&GraphNode.changeset(%GraphNode{}, &1))
    |> Repo.insert()
  end

  def upsert_memory_edge(attrs) when is_map(attrs) do
    attrs
    |> normalize_edge_attrs()
    |> then(&GraphEdge.changeset(%GraphEdge{}, &1))
    |> Repo.insert()
  end

  def list_session_nodes(session_id), do: Repo.list_graph_nodes(session_id)
  def list_session_edges(session_id), do: Repo.list_graph_edges(session_id)

  def record_execution(session_id, attrs) when is_binary(session_id) and is_map(attrs) do
    with {:ok, %GraphNode{} = node} <-
           upsert_memory_node(%{
             session_id: session_id,
             node_type: "execution",
             scope: "session",
             name: Map.get(attrs, :name) || Map.get(attrs, "name") || "execution",
             content: Map.get(attrs, :content) || Map.get(attrs, "content") || "",
             metadata: Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}
           }) do
      maybe_link_latest_day_summary(session_id, node)
      {:ok, node}
    end
  end

  def refresh_day_summary(session_id, opts \\ []) when is_binary(session_id) do
    token_budget = Keyword.get(opts, :token_budget, 300)

    content =
      session_id
      |> list_session_nodes()
      |> Enum.filter(&(&1.node_type == "execution" and is_nil(&1.valid_until)))
      |> Enum.sort_by(& &1.inserted_at, {:desc, NaiveDateTime})
      |> Enum.map(& &1.content)
      |> take_within_budget(token_budget)
      |> Enum.join("\n")

    if content == "" do
      {:error, :no_execution_history}
    else
      upsert_memory_node(%{
        session_id: session_id,
        node_type: "day_summary",
        scope: "day",
        name: "daily-summary",
        content: content,
        metadata: %{"kind" => "auto"}
      })
    end
  end

  def seed_session_memory(session_id, metadata) when is_binary(session_id) and is_map(metadata) do
    seed_nodes = [
      build_seed_node(session_id, "preference", "user-locale", locale_preference(metadata)),
      build_seed_node(session_id, "style", "response-style", Map.get(metadata, "response_style")),
      build_seed_node(session_id, "personality", "orchestrator-personality", Map.get(metadata, "orchestrator_personality"))
    ]

    seed_nodes
    |> Enum.reject(&is_nil/1)
    |> Enum.each(&upsert_memory_node/1)

    :ok
  end

  def orchestrator_memory_summary(session_id, opts \\ []) do
    token_budget = Keyword.get(opts, :token_budget, 300)

    summary =
      session_id
      |> list_session_nodes()
      |> filter_current_memory_nodes()
      |> Enum.sort_by(&memory_priority/1)
      |> Enum.map(& &1.content)
      |> take_within_budget(token_budget)
      |> Enum.join("\n")

    if summary == "", do: {:error, :no_memory}, else: {:ok, summary}
  end

  def refresh_session_summary(session_id, opts \\ []) when is_binary(session_id) do
    with {:ok, summary} <- orchestrator_memory_summary(session_id, opts),
         :ok <- ElixirClaw.Session.Manager.put_metadata(session_id, %{"orchestrator_memory_summary" => summary}) do
      {:ok, summary}
    end
  end

  defp maybe_link_latest_day_summary(session_id, %GraphNode{} = node) do
    case latest_day_summary(session_id) do
      %GraphNode{} = summary_node ->
        _ =
          upsert_memory_edge(%{
            session_id: session_id,
            source_node_id: summary_node.id,
            target_node_id: node.id,
            relation_type: "temporal",
            metadata: %{}
          })

        :ok

      nil ->
        :ok
    end
  end

  defp locale_preference(metadata) do
    case Map.get(metadata, "locale") do
      locale when is_binary(locale) and locale not in ["", "en"] -> "The user prefers #{locale}."
      _ -> nil
    end
  end

  defp build_seed_node(_session_id, _type, _name, nil), do: nil

  defp build_seed_node(session_id, type, name, content) when is_binary(content) do
    %{
      session_id: session_id,
      node_type: type,
      scope: if(type == "preference", do: "user", else: "global"),
      name: name,
      content: content,
      metadata: %{"kind" => "seed"}
    }
  end

  defp latest_day_summary(session_id) do
    session_id
    |> list_session_nodes()
    |> Enum.filter(&(&1.node_type == "day_summary"))
    |> Enum.max_by(& &1.inserted_at, NaiveDateTime)
  rescue
    Enum.EmptyError -> nil
  end

  defp normalize_node_attrs(attrs) do
    %{
      id: Map.get(attrs, :id) || Map.get(attrs, "id"),
      session_id: Map.get(attrs, :session_id) || Map.get(attrs, "session_id"),
      node_type: Map.get(attrs, :node_type) || Map.get(attrs, "node_type"),
      scope: Map.get(attrs, :scope) || Map.get(attrs, "scope", "session"),
      name: Map.get(attrs, :name) || Map.get(attrs, "name"),
      content: Map.get(attrs, :content) || Map.get(attrs, "content"),
      metadata: Map.get(attrs, :metadata) || Map.get(attrs, "metadata", %{}),
      valid_from: Map.get(attrs, :valid_from) || Map.get(attrs, "valid_from"),
      valid_until: Map.get(attrs, :valid_until) || Map.get(attrs, "valid_until"),
      confidence: Map.get(attrs, :confidence) || Map.get(attrs, "confidence", 1.0)
    }
  end

  defp normalize_edge_attrs(attrs) do
    %{
      id: Map.get(attrs, :id) || Map.get(attrs, "id"),
      session_id: Map.get(attrs, :session_id) || Map.get(attrs, "session_id"),
      source_node_id: Map.get(attrs, :source_node_id) || Map.get(attrs, "source_node_id"),
      target_node_id: Map.get(attrs, :target_node_id) || Map.get(attrs, "target_node_id"),
      relation_type: Map.get(attrs, :relation_type) || Map.get(attrs, "relation_type"),
      metadata: Map.get(attrs, :metadata) || Map.get(attrs, "metadata", %{}),
      valid_at: Map.get(attrs, :valid_at) || Map.get(attrs, "valid_at"),
      invalid_at: Map.get(attrs, :invalid_at) || Map.get(attrs, "invalid_at")
    }
  end

  defp filter_current_memory_nodes(nodes) do
    Enum.filter(nodes, fn node ->
      is_nil(node.valid_until) and node.node_type in ["style", "personality", "preference", "day_summary", "execution"]
    end)
  end

  defp memory_priority(%GraphNode{node_type: "style"}), do: 1
  defp memory_priority(%GraphNode{node_type: "personality"}), do: 2
  defp memory_priority(%GraphNode{node_type: "preference"}), do: 3
  defp memory_priority(%GraphNode{node_type: "day_summary"}), do: 4
  defp memory_priority(%GraphNode{node_type: "execution"}), do: 5
  defp memory_priority(_node), do: 99

  defp take_within_budget(contents, token_budget) do
    Enum.reduce_while(contents, {[], 0}, fn content, {acc, used} ->
      tokens = ElixirClaw.Agent.ContextBuilder.estimate_tokens(content)

      if used + tokens <= token_budget do
        {:cont, {[content | acc], used + tokens}}
      else
        {:halt, {Enum.reverse(acc), used}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
