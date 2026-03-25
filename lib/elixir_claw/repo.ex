defmodule ElixirClaw.Repo do
  @moduledoc false

  use GenServer

  alias ElixirClaw.Schema.{GraphEdge, GraphNode, Message, Session}

  @sessions_relation "sessions"
  @messages_relation "messages"
  @graph_nodes_relation "graph_nodes"
  @graph_edges_relation "graph_edges"

  @sessions_headers [
    "id",
    "channel",
    "channel_user_id",
    "provider",
    "model",
    "token_count_in",
    "token_count_out",
    "metadata",
    "inserted_at",
    "updated_at"
  ]

  @messages_headers [
    "id",
    "session_id",
    "role",
    "content",
    "tool_calls",
    "tool_call_id",
    "token_count",
    "inserted_at"
  ]

  @graph_nodes_headers [
    "id",
    "session_id",
    "node_type",
    "scope",
    "name",
    "content",
    "metadata",
    "valid_from",
    "valid_until",
    "confidence",
    "inserted_at",
    "updated_at"
  ]

  @graph_edges_headers [
    "id",
    "session_id",
    "source_node_id",
    "target_node_id",
    "relation_type",
    "metadata",
    "valid_at",
    "invalid_at",
    "inserted_at"
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def insert(changeset), do: GenServer.call(__MODULE__, {:insert, changeset})
  def insert!(changeset), do: unwrap_ok!(insert(changeset))
  def update(changeset), do: GenServer.call(__MODULE__, {:update, changeset})
  def update!(changeset), do: unwrap_ok!(update(changeset))
  def get(schema_module, id), do: GenServer.call(__MODULE__, {:get, schema_module, id})
  def get!(schema_module, id), do: unwrap_found!(get(schema_module, id), schema_module, id)
  def delete(struct), do: GenServer.call(__MODULE__, {:delete, struct})
  def delete_all(schema_module), do: GenServer.call(__MODULE__, {:delete_all, schema_module})
  def reset!, do: GenServer.call(__MODULE__, :reset)

  def list_session_messages(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:list_session_messages, session_id})
  end

  def count_session_messages(session_id) when is_binary(session_id),
    do: length(list_session_messages(session_id))

  def sum_session_message_tokens(session_id) when is_binary(session_id) do
    Enum.reduce(list_session_messages(session_id), 0, &(&1.token_count + &2))
  end

  def find_session(channel, provider, channel_user_id)
      when is_binary(channel) and is_binary(provider) and is_binary(channel_user_id) do
    GenServer.call(__MODULE__, {:find_session, channel, provider, channel_user_id})
  end

  def replace_session_messages(session_id, messages)
      when is_binary(session_id) and is_list(messages) do
    GenServer.call(__MODULE__, {:replace_session_messages, session_id, messages})
  end

  def insert_message(attrs) when is_map(attrs),
    do: GenServer.call(__MODULE__, {:insert_message, attrs})

  def list_graph_nodes(session_id) when is_binary(session_id),
    do: GenServer.call(__MODULE__, {:list_graph_nodes, session_id})

  def list_graph_edges(session_id) when is_binary(session_id),
    do: GenServer.call(__MODULE__, {:list_graph_edges, session_id})

  def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}

  def query!(statement) when is_binary(statement),
    do: if(String.trim(statement) == "", do: :ok, else: :ok)

  @impl true
  def init(_opts) do
    config = Application.get_env(:elixir_claw, __MODULE__, [])
    engine = Keyword.get(config, :engine, :sqlite)
    path = Keyword.get(config, :path, "elixir_claw_dev.cozo.db")

    with :ok <- ensure_parent_directory(engine, path),
         {:ok, port} <- open_bridge(engine, path),
         :ok <- bridge_request(port, %{cmd: "ensure_relations", relations: relation_specs()}) do
      {:ok, %{port: port, engine: engine, path: path}}
    end
  end

  @impl true
  def terminate(_reason, %{port: port}) do
    _ = Port.command(port, Jason.encode!(%{id: 0, cmd: "close"}) <> "\n")
    Port.close(port)
    :ok
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, request!(state, %{cmd: "reset_relations", relations: relation_specs()}), state}
  end

  def handle_call({:insert, changeset}, _from, state) do
    {:reply, persist_changeset(state, changeset), state}
  end

  def handle_call({:update, changeset}, _from, state) do
    {:reply, persist_changeset(state, changeset), state}
  end

  def handle_call({:get, schema_module, id}, _from, state) do
    {:reply, get_record(state, schema_module, id), state}
  end

  def handle_call({:delete, %schema_module{} = struct}, _from, state) do
    {:reply, delete_record(state, schema_module, struct), state}
  end

  def handle_call({:delete_all, schema_module}, _from, state) do
    {:reply, delete_all_records(state, schema_module), state}
  end

  def handle_call({:list_session_messages, session_id}, _from, state) do
    {:reply, list_messages(state, session_id), state}
  end

  def handle_call({:find_session, channel, provider, channel_user_id}, _from, state) do
    {:reply, find_session_record(state, channel, provider, channel_user_id), state}
  end

  def handle_call({:replace_session_messages, session_id, messages}, _from, state) do
    {:reply, replace_messages(state, session_id, messages), state}
  end

  def handle_call({:insert_message, attrs}, _from, state) do
    {:reply, persist_changeset(state, Message.changeset(%Message{}, attrs)), state}
  end

  def handle_call({:list_graph_nodes, session_id}, _from, state) do
    {:reply, list_graph_nodes_for_session(state, session_id), state}
  end

  def handle_call({:list_graph_edges, session_id}, _from, state) do
    {:reply, list_graph_edges_for_session(state, session_id), state}
  end

  defp persist_changeset(_state, %Ecto.Changeset{valid?: false} = changeset),
    do: {:error, changeset}

  defp persist_changeset(state, %Session{} = session), do: persist_session(state, session)

  defp persist_changeset(state, %Message{} = message),
    do: persist_message(state, message, Message.changeset(%Message{}, Map.from_struct(message)))

  defp persist_changeset(state, %Ecto.Changeset{} = changeset) do
    case Ecto.Changeset.apply_changes(changeset) do
      %Session{} = session -> persist_session(state, session)
      %Message{} = message -> persist_message(state, message, changeset)
      %GraphNode{} = node -> persist_graph_node(state, node)
      %GraphEdge{} = edge -> persist_graph_edge(state, edge)
      _ -> {:error, changeset}
    end
  end

  defp persist_changeset(state, %GraphNode{} = node), do: persist_graph_node(state, node)
  defp persist_changeset(state, %GraphEdge{} = edge), do: persist_graph_edge(state, edge)

  defp persist_session(state, %Session{} = session) do
    now = now_naive()

    persisted = %Session{
      session
      | id: session.id || Ecto.UUID.generate(),
        metadata: session.metadata || %{},
        inserted_at: session.inserted_at || now,
        updated_at: now
    }

    case put_rows(state, @sessions_relation, @sessions_headers, [session_row(persisted)]) do
      :ok -> {:ok, persisted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_message(state, %Message{} = message, %Ecto.Changeset{} = changeset) do
    if is_nil(get_record(state, Session, message.session_id)) do
      {:error, Ecto.Changeset.add_error(changeset, :session_id, "does not exist")}
    else
      persisted = %Message{
        message
        | id: message.id || Ecto.UUID.generate(),
          inserted_at: message.inserted_at || now_naive()
      }

      case put_rows(state, @messages_relation, @messages_headers, [message_row(persisted)]) do
        :ok -> {:ok, persisted}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp get_record(state, Session, id),
    do: find_by_id(export_rows(state, @sessions_relation), id, &session_from_row/1)

  defp get_record(state, Message, id),
    do: find_by_id(export_rows(state, @messages_relation), id, &message_from_row/1)

  defp get_record(state, GraphNode, id),
    do: find_by_id(export_rows(state, @graph_nodes_relation), id, &graph_node_from_row/1)

  defp get_record(state, GraphEdge, id),
    do: find_by_id(export_rows(state, @graph_edges_relation), id, &graph_edge_from_row/1)

  defp get_record(_state, _schema_module, _id), do: nil

  defp delete_record(state, Session, %Session{id: id} = session) do
    with :ok <- delete_rows(state, @messages_relation, ["id"], message_ids_for_session(state, id)),
         :ok <- delete_rows(state, @sessions_relation, ["id"], [[id]]) do
      {:ok, session}
    end
  end

  defp delete_record(state, Message, %Message{id: id} = message) do
    with :ok <- delete_rows(state, @messages_relation, ["id"], [[id]]) do
      {:ok, message}
    end
  end

  defp delete_all_records(state, Session) do
    with :ok <- delete_relation_rows(state, @messages_relation),
         :ok <- delete_relation_rows(state, @sessions_relation) do
      :ok
    end
  end

  defp delete_all_records(state, Message), do: delete_relation_rows(state, @messages_relation)
  defp delete_all_records(state, GraphNode), do: delete_relation_rows(state, @graph_nodes_relation)
  defp delete_all_records(state, GraphEdge), do: delete_relation_rows(state, @graph_edges_relation)

  defp list_messages(state, session_id) do
    state
    |> export_rows(@messages_relation)
    |> Enum.map(&message_from_row/1)
    |> Enum.filter(&(&1.session_id == session_id))
      |> Enum.sort_by(&{&1.inserted_at, &1.id})
  end

  defp list_graph_nodes_for_session(state, session_id) do
    state
    |> export_rows(@graph_nodes_relation)
    |> Enum.map(&graph_node_from_row/1)
    |> Enum.filter(&(&1.session_id == session_id))
    |> Enum.sort_by(&{&1.inserted_at, &1.id})
  end

  defp list_graph_edges_for_session(state, session_id) do
    state
    |> export_rows(@graph_edges_relation)
    |> Enum.map(&graph_edge_from_row/1)
    |> Enum.filter(&(&1.session_id == session_id))
    |> Enum.sort_by(&{&1.inserted_at, &1.id})
  end

  defp find_session_record(state, channel, provider, channel_user_id) do
    state
    |> export_rows(@sessions_relation)
    |> Enum.map(&session_from_row/1)
    |> Enum.find(fn session ->
      session.channel == channel and session.provider == provider and
        session.channel_user_id == channel_user_id
    end)
  end

  defp replace_messages(state, session_id, messages) do
    with :ok <-
           delete_rows(
             state,
             @messages_relation,
             ["id"],
             message_ids_for_session(state, session_id)
           ),
         :ok <-
           put_rows(
             state,
             @messages_relation,
             @messages_headers,
             Enum.map(messages, &message_row/1)
           ) do
      {:ok, messages}
    end
  end

  defp message_ids_for_session(state, session_id) do
    state
    |> export_rows(@messages_relation)
    |> Enum.filter(fn [_, row_session_id | _rest] -> row_session_id == session_id end)
    |> Enum.map(fn [id | _rest] -> [id] end)
  end

  defp find_by_id(rows, id, mapper) do
    case Enum.find(rows, fn [row_id | _rest] -> row_id == id end) do
      nil -> nil
      row -> mapper.(row)
    end
  end

  defp export_rows(state, relation) do
    case request!(state, %{cmd: "export_relations", names: [relation]}) do
      {:ok, data} ->
        relation_data = Map.get(data, relation) || Map.get(data, String.to_atom(relation)) || %{}
        Map.get(relation_data, "rows") || Map.get(relation_data, :rows) || []

      {:error, _reason} ->
        []
    end
  end

  defp put_rows(_state, _relation, _headers, []), do: :ok

  defp put_rows(state, relation, headers, rows) do
    case request!(state, %{
           cmd: "import_relations",
           data: %{relation => %{headers: headers, rows: rows}}
         }) do
      :ok -> :ok
      {:ok, _data} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_rows(_state, _relation, _headers, []), do: :ok

  defp delete_rows(state, relation, headers, rows) do
    case request!(state, %{
           cmd: "import_relations",
           data: %{"-#{relation}" => %{headers: headers, rows: rows}}
         }) do
      :ok -> :ok
      {:ok, _data} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_relation_rows(state, relation) do
    rows = export_rows(state, relation) |> Enum.map(fn [id | _] -> [id] end)
    delete_rows(state, relation, ["id"], rows)
  end

  defp request!(state, payload) do
    bridge_request(state.port, Map.put(payload, :id, 1))
  end

  defp bridge_request(port, payload) do
    Port.command(port, Jason.encode!(payload) <> "\n")

    receive_bridge_response(port, "")
  end

  defp receive_bridge_response(port, buffer) do
    receive do
      {^port, {:data, data}} ->
        combined = buffer <> to_string(data)

        if String.contains?(combined, "\n") do
          [line | _rest] = String.split(combined, "\n", parts: 2)
          parse_bridge_line(line)
        else
          receive_bridge_response(port, combined)
        end

      {^port, {:exit_status, status}} ->
        {:error, {:bridge_exit, status}}
    after
      30_000 -> {:error, :bridge_timeout}
    end
  end

  defp parse_bridge_line(line) do
    case Jason.decode(line) do
      {:ok, %{"ok" => true, "data" => response_data}} -> {:ok, response_data}
      {:ok, %{"ok" => true}} -> :ok
      {:ok, %{"ok" => false, "error" => error}} -> {:error, error}
      _ -> {:error, :bridge_no_response}
    end
  end

  defp open_bridge(engine, path) do
    node = System.find_executable("node") || System.find_executable("node.exe")

    if is_nil(node) do
      {:error, :node_not_found}
    else
      script_path = Path.expand("../../priv/cozo_bridge/index.cjs", __DIR__)

      {:ok,
       Port.open({:spawn_executable, node}, [
         :binary,
         :exit_status,
         :use_stdio,
         :stderr_to_stdout,
         args: [script_path, Atom.to_string(engine), path]
       ])}
    end
  end

  defp ensure_parent_directory(:mem, _path), do: :ok

  defp ensure_parent_directory(_engine, path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp relation_specs do
    [
      %{
        name: @sessions_relation,
        spec:
          "id => channel, channel_user_id, provider, model, token_count_in, token_count_out, metadata, inserted_at, updated_at"
      },
      %{
        name: @messages_relation,
        spec:
          "id => session_id, role, content, tool_calls, tool_call_id, token_count, inserted_at"
      },
      %{
        name: @graph_nodes_relation,
        spec:
          "id => session_id, node_type, scope, name, content, metadata, valid_from, valid_until, confidence, inserted_at, updated_at"
      },
      %{
        name: @graph_edges_relation,
        spec:
          "id => session_id, source_node_id, target_node_id, relation_type, metadata, valid_at, invalid_at, inserted_at"
      }
    ]
  end

  defp persist_graph_node(state, %GraphNode{} = node) do
    now = now_naive()

    persisted = %GraphNode{
      node
      | id: node.id || Ecto.UUID.generate(),
        metadata: node.metadata || %{},
        valid_from: node.valid_from || now,
        inserted_at: node.inserted_at || now,
        updated_at: now
    }

    case put_rows(state, @graph_nodes_relation, @graph_nodes_headers, [graph_node_row(persisted)]) do
      :ok -> {:ok, persisted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_graph_edge(state, %GraphEdge{} = edge) do
    now = now_naive()

    persisted = %GraphEdge{
      edge
      | id: edge.id || Ecto.UUID.generate(),
        metadata: edge.metadata || %{},
        valid_at: edge.valid_at || now,
        inserted_at: edge.inserted_at || now
    }

    case put_rows(state, @graph_edges_relation, @graph_edges_headers, [graph_edge_row(persisted)]) do
      :ok -> {:ok, persisted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp session_row(%Session{} = session) do
    [
      session.id,
      session.channel,
      session.channel_user_id,
      session.provider,
      session.model,
      session.token_count_in,
      session.token_count_out,
      Jason.encode!(session.metadata || %{}),
      encode_naive(session.inserted_at),
      encode_naive(session.updated_at)
    ]
  end

  defp message_row(%Message{} = message) do
    [
      message.id,
      message.session_id,
      message.role,
      message.content,
      encode_optional_json(message.tool_calls),
      message.tool_call_id,
      message.token_count,
      encode_naive(message.inserted_at)
    ]
  end

  defp graph_node_row(%GraphNode{} = node) do
    [
      node.id,
      node.session_id,
      node.node_type,
      node.scope,
      node.name,
      node.content,
      Jason.encode!(node.metadata || %{}),
      encode_naive(node.valid_from),
      encode_optional_naive(node.valid_until),
      node.confidence,
      encode_naive(node.inserted_at),
      encode_naive(node.updated_at)
    ]
  end

  defp graph_edge_row(%GraphEdge{} = edge) do
    [
      edge.id,
      edge.session_id,
      edge.source_node_id,
      edge.target_node_id,
      edge.relation_type,
      Jason.encode!(edge.metadata || %{}),
      encode_naive(edge.valid_at),
      encode_optional_naive(edge.invalid_at),
      encode_naive(edge.inserted_at)
    ]
  end

  defp session_from_row([
         id,
         channel,
         channel_user_id,
         provider,
         model,
         token_count_in,
         token_count_out,
         metadata,
         inserted_at,
         updated_at
       ]) do
    %Session{
      id: id,
      channel: channel,
      channel_user_id: channel_user_id,
      provider: provider,
      model: model,
      token_count_in: token_count_in || 0,
      token_count_out: token_count_out || 0,
      metadata: decode_json_map(metadata),
      inserted_at: decode_naive(inserted_at),
      updated_at: decode_naive(updated_at)
    }
  end

  defp message_from_row([
         id,
         session_id,
         role,
         content,
         tool_calls,
         tool_call_id,
         token_count,
         inserted_at
       ]) do
    %Message{
      id: id,
      session_id: session_id,
      role: role,
      content: content,
      tool_calls: decode_optional_json(tool_calls),
      tool_call_id: tool_call_id,
      token_count: token_count || 0,
      inserted_at: decode_naive(inserted_at)
    }
  end

  defp graph_node_from_row([
         id,
         session_id,
         node_type,
         scope,
         name,
         content,
         metadata,
         valid_from,
         valid_until,
         confidence,
         inserted_at,
         updated_at
       ]) do
    %GraphNode{
      id: id,
      session_id: session_id,
      node_type: node_type,
      scope: scope,
      name: name,
      content: content,
      metadata: decode_json_map(metadata),
      valid_from: decode_naive(valid_from),
      valid_until: decode_optional_naive(valid_until),
      confidence: confidence || 1.0,
      inserted_at: decode_naive(inserted_at),
      updated_at: decode_naive(updated_at)
    }
  end

  defp graph_edge_from_row([
         id,
         session_id,
         source_node_id,
         target_node_id,
         relation_type,
         metadata,
         valid_at,
         invalid_at,
         inserted_at
       ]) do
    %GraphEdge{
      id: id,
      session_id: session_id,
      source_node_id: source_node_id,
      target_node_id: target_node_id,
      relation_type: relation_type,
      metadata: decode_json_map(metadata),
      valid_at: decode_naive(valid_at),
      invalid_at: decode_optional_naive(invalid_at),
      inserted_at: decode_naive(inserted_at)
    }
  end

  defp encode_optional_json(nil), do: nil
  defp encode_optional_json(value), do: Jason.encode!(value)

  defp decode_optional_json(nil), do: nil
  defp decode_optional_json(""), do: nil
  defp decode_optional_json(value) when is_binary(value), do: decode_json(value)
  defp decode_optional_json(value), do: value

  defp decode_json_map(value) when is_binary(value) do
    case decode_json(value) do
      decoded when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_json_map(_value), do: %{}

  defp decode_json(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> value
    end
  end

  defp encode_naive(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp encode_naive(%DateTime{} = value), do: value |> DateTime.to_naive() |> encode_naive()
  defp encode_naive(nil), do: encode_naive(now_naive())

  defp encode_optional_naive(nil), do: nil
  defp encode_optional_naive(value), do: encode_naive(value)

  defp decode_naive(nil), do: now_naive()

  defp decode_naive(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> naive
      _ -> now_naive()
    end
  end

  defp decode_optional_naive(nil), do: nil
  defp decode_optional_naive(value), do: decode_naive(value)

  defp now_naive do
    microseconds = DateTime.utc_now() |> DateTime.to_unix(:microsecond)
    unique_offset = rem(System.unique_integer([:positive, :monotonic]), 1_000)

    (microseconds + unique_offset)
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:microsecond)
  end

  defp unwrap_ok!({:ok, value}), do: value
  defp unwrap_ok!({:error, reason}), do: raise("Repo operation failed: #{inspect(reason)}")

  defp unwrap_found!(nil, schema_module, id),
    do: raise("#{inspect(schema_module)} #{id} not found")

  defp unwrap_found!(value, _schema_module, _id), do: value
end
