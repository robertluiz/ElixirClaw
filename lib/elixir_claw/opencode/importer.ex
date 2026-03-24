defmodule ElixirClaw.OpenCode.Importer do
  @moduledoc false

  import Ecto.Query

  alias ElixirClaw.OpenCode.Schema.Message, as: OpenCodeMessage
  alias ElixirClaw.OpenCode.Schema.Part, as: OpenCodePart
  alias ElixirClaw.OpenCode.Schema.Session, as: OpenCodeSession
  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.Message, as: LocalMessage
  alias ElixirClaw.Schema.Session, as: LocalSession
  alias ElixirClaw.Session.Manager
  alias ElixirClaw.Types.Message, as: MessageType

  @max_tool_result_bytes 10 * 1024
  @default_limit 50

  @spec list_sessions(Path.t(), keyword()) ::
          {:ok, [map()]} | {:error, :db_not_found | :invalid_db}
  def list_sessions(db_path, opts \\ []) do
    with_source_db(db_path, fn conn ->
      {:ok,
       conn
       |> fetch_sessions(opts)
       |> Enum.map(&map_session_summary/1)}
    end)
  end

  @spec import_session(Path.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def import_session(db_path, session_id) do
    normalized_session_id = normalize_session_id(session_id)

    with_source_db(db_path, fn conn ->
      case fetch_source_session(conn, normalized_session_id) do
        nil ->
          {:error, :session_not_found}

        source_session ->
          with {:ok, local_session_id} <- start_local_session(source_session),
               {:ok, _count} <-
                 import_messages_into_local_session(conn, source_session, local_session_id, nil) do
            {:ok, local_session_id}
          else
            {:error, reason} ->
              cleanup_local_session(normalized_id(source_session.id))
              {:error, reason}
          end
      end
    end)
  end

  @spec import_messages(Path.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def import_messages(db_path, session_id, opts \\ []) do
    normalized_session_id = normalize_session_id(session_id)

    with_source_db(db_path, fn conn ->
      case fetch_source_session(conn, normalized_session_id) do
        nil ->
          {:error, :session_not_found}

        source_session ->
          with {:ok, local_session_id} <- fetch_local_session_id(normalized_id(source_session.id)),
               {:ok, count} <-
                 import_messages_into_local_session(
                   conn,
                   source_session,
                   local_session_id,
                   opts[:since]
                 ) do
            {:ok, count}
          end
      end
    end)
  end

  defp with_source_db(db_path, fun) do
    with :ok <- validate_db_path(db_path),
         {:ok, conn} <- Exqlite.Sqlite3.open(db_path, [:readonly]),
         :ok <- validate_schema(conn) do
      try do
        fun.(conn)
      after
        Exqlite.Sqlite3.close(conn)
      end
    else
      {:error, %Exqlite.Error{}} -> {:error, :invalid_db}
      {:error, _reason} = error -> error
    end
  end

  defp validate_db_path(db_path) when is_binary(db_path) do
    if File.regular?(db_path), do: :ok, else: {:error, :db_not_found}
  end

  defp validate_schema(conn) do
    sql =
      "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('sessions', 'messages', 'parts') ORDER BY name"

    case query_rows(conn, sql) do
      {:ok, [["messages"], ["parts"], ["sessions"]]} -> :ok
      _ -> {:error, :invalid_db}
    end
  end

  defp fetch_sessions(conn, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)

    sql =
      """
      SELECT id, project_id, title, directory, time_created, time_updated, summary_diffs, parent_id
      FROM sessions
      WHERE (?1 IS NULL OR directory = ?1)
        AND (?2 IS NULL OR LOWER(title) LIKE LOWER(?2) OR LOWER(directory) LIKE LOWER(?2))
      ORDER BY time_updated DESC, id DESC
      LIMIT ?3
      """

    search = opts[:search] && "%#{opts[:search]}%"

    case query_rows(conn, sql, [opts[:directory], search, limit]) do
      {:ok, rows} -> Enum.map(rows, &to_session/1)
      {:error, _reason} -> []
    end
  end

  defp fetch_source_session(conn, session_id) do
    sql =
      """
      SELECT id, project_id, title, directory, time_created, time_updated, summary_diffs, parent_id
      FROM sessions
      WHERE id = ?1
      LIMIT 1
      """

    case query_rows(conn, sql, [session_id]) do
      {:ok, [row]} -> to_session(row)
      _ -> nil
    end
  end

  defp fetch_source_messages(conn, session_id, since) do
    sql =
      """
      SELECT id, session_id, time_created, time_updated, data
      FROM messages
      WHERE session_id = ?1
        AND (?2 IS NULL OR time_created > ?2)
      ORDER BY time_created ASC, id ASC
      """

    case query_rows(conn, sql, [session_id, since]) do
      {:ok, rows} -> Enum.map(rows, &to_message/1)
      _ -> []
    end
  end

  defp fetch_source_parts(conn, session_id) do
    sql =
      """
      SELECT id, message_id, session_id, time_created, data
      FROM parts
      WHERE session_id = ?1
      ORDER BY time_created ASC, id ASC
      """

    case query_rows(conn, sql, [session_id]) do
      {:ok, rows} -> Enum.map(rows, &to_part/1)
      _ -> []
    end
  end

  defp query_rows(conn, sql, params \\ []) do
    with {:ok, statement} <- Exqlite.Sqlite3.prepare(conn, sql) do
      try do
        :ok = Exqlite.Sqlite3.bind(statement, params)
        Exqlite.Sqlite3.fetch_all(conn, statement)
      after
        Exqlite.Sqlite3.release(conn, statement)
      end
    end
  end

  defp to_session([
         id,
         project_id,
         title,
         directory,
         time_created,
         time_updated,
         summary_diffs,
         parent_id
       ]) do
    struct(OpenCodeSession, %{
      id: id,
      project_id: project_id,
      title: title,
      directory: directory,
      time_created: time_created,
      time_updated: time_updated,
      summary_diffs: summary_diffs,
      parent_id: parent_id
    })
  end

  defp to_message([id, session_id, time_created, time_updated, data]) do
    struct(OpenCodeMessage, %{
      id: id,
      session_id: session_id,
      time_created: time_created,
      time_updated: time_updated,
      data: data
    })
  end

  defp to_part([id, message_id, session_id, time_created, data]) do
    struct(OpenCodePart, %{
      id: id,
      message_id: message_id,
      session_id: session_id,
      time_created: time_created,
      data: data
    })
  end

  defp map_session_summary(%OpenCodeSession{} = session) do
    %{
      id: normalized_id(session.id),
      title: session.title,
      directory: session.directory,
      project_id: session.project_id,
      parent_id: normalized_optional_id(session.parent_id),
      created_at: datetime_from_unix_ms(session.time_created),
      updated_at: datetime_from_unix_ms(session.time_updated)
    }
  end

  defp start_local_session(%OpenCodeSession{} = source_session) do
    Manager.start_session(%{
      channel: "opencode",
      channel_user_id: normalized_id(source_session.id),
      provider: "opencode",
      model: "opencode",
      metadata: %{
        "source" => "opencode",
        "source_session_id" => normalized_id(source_session.id),
        "project_id" => source_session.project_id,
        "title" => source_session.title,
        "directory" => source_session.directory,
        "parent_id" => normalized_optional_id(source_session.parent_id),
        "summary_diffs" => decode_json_string(source_session.summary_diffs)
      }
    })
  end

  defp fetch_local_session_id(source_session_id) do
    case Repo.one(
           from(session in LocalSession,
             where:
               session.channel == "opencode" and
                 session.provider == "opencode" and
                 session.channel_user_id == ^source_session_id,
             select: session.id,
             limit: 1
           )
         ) do
      nil -> {:error, :session_not_imported}
      session_id -> {:ok, session_id}
    end
  end

  defp import_messages_into_local_session(
         conn,
         %OpenCodeSession{} = source_session,
         local_session_id,
         since
       ) do
    part_map =
      conn
      |> fetch_source_parts(source_session.id)
      |> Enum.group_by(& &1.message_id)

    messages = fetch_source_messages(conn, source_session.id, since)

    Repo.transaction(fn ->
      Enum.reduce(messages, 0, fn source_message, count ->
        mapped_message =
          map_message(source_message, Map.get(part_map, source_message.id, []), local_session_id)

        %LocalMessage{id: mapped_message.id, inserted_at: mapped_message.inserted_at}
        |> LocalMessage.changeset(mapped_message.attrs)
        |> Repo.insert!()

        count + 1
      end)
    end)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, _operation, reason, _changes} -> {:error, reason}
    end
  end

  defp map_message(%OpenCodeMessage{} = source_message, parts, local_session_id) do
    payload = decode_json_string(source_message.data)
    role = payload_role(payload)

    content =
      payload
      |> payload_texts()
      |> Kernel.++(part_texts(parts))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    timestamp = datetime_from_unix_ms(source_message.time_created)
    role_string = Atom.to_string(role)

    %{
      id: normalized_id(source_message.id),
      inserted_at: timestamp |> DateTime.to_naive() |> NaiveDateTime.truncate(:second),
      attrs: %{
        session_id: local_session_id,
        role: role_string,
        content: content,
        token_count:
          MessageType.estimated_tokens(%MessageType{
            role: role_string,
            content: content,
            timestamp: timestamp
          })
      }
    }
  end

  defp payload_role(%{"role" => "user"}), do: :user
  defp payload_role(%{"role" => "assistant"}), do: :assistant
  defp payload_role(%{"role" => "system"}), do: :system
  defp payload_role(%{"role" => "tool"}), do: :tool
  defp payload_role(_), do: :assistant

  defp payload_texts(%{"content" => content}) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      %{"text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
  end

  defp payload_texts(_), do: []

  defp part_texts(parts) do
    Enum.flat_map(parts, fn part ->
      case decode_json_string(part.data) do
        %{"text" => text} when is_binary(text) ->
          [text]

        %{"tool_results" => tool_results} when is_list(tool_results) ->
          Enum.flat_map(tool_results, &tool_result_text/1)

        _ ->
          []
      end
    end)
  end

  defp tool_result_text(value) when is_binary(value), do: sized_text(value)
  defp tool_result_text(%{"content" => content}) when is_binary(content), do: sized_text(content)
  defp tool_result_text(%{"text" => text}) when is_binary(text), do: sized_text(text)
  defp tool_result_text(%{"output" => output}) when is_binary(output), do: sized_text(output)
  defp tool_result_text(%{"result" => result}) when is_binary(result), do: sized_text(result)
  defp tool_result_text(_), do: []

  defp sized_text(text) when byte_size(text) > @max_tool_result_bytes, do: []
  defp sized_text(text), do: [text]

  defp decode_json_string(nil), do: %{}

  defp decode_json_string(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, decoded} when is_list(decoded) -> %{"items" => decoded}
      _ -> %{}
    end
  end

  defp datetime_from_unix_ms(nil), do: nil
  defp datetime_from_unix_ms(value), do: DateTime.from_unix!(value, :millisecond)

  defp normalized_id(id) when is_binary(id) do
    id
    |> String.replace_prefix("session_", "")
    |> String.replace_prefix("message_", "")
    |> String.replace_prefix("part_", "")
  end

  defp normalized_optional_id(nil), do: nil
  defp normalized_optional_id(id), do: normalized_id(id)

  defp normalize_session_id(id) when is_binary(id) do
    if String.starts_with?(id, "session_"), do: id, else: "session_" <> id
  end

  defp cleanup_local_session(source_session_id) do
    case fetch_local_session_id(source_session_id) do
      {:ok, local_session_id} ->
        _ = Manager.end_session(local_session_id)

        case Repo.get(LocalSession, local_session_id) do
          nil ->
            :ok

          session ->
            _ = Repo.delete(session)
            :ok
        end

      _ ->
        :ok
    end
  end
end
