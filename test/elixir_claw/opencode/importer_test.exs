defmodule ElixirClaw.OpenCode.ImporterTest do
  use ExUnit.Case, async: false

  alias ElixirClaw.OpenCode.Importer
  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.{Message, Session}
  alias ElixirClaw.Session.Manager

  @fixtures_dir Path.expand("../fixtures/opencode", __DIR__)
  @db_path Path.join(@fixtures_dir, "test_opencode.db")
  @invalid_db_path Path.join(@fixtures_dir, "invalid.db")

  setup do
    File.mkdir_p!(@fixtures_dir)
    File.rm(@db_path)
    File.rm(@invalid_db_path)

    create_opencode_db!(@db_path)
    File.write!(@invalid_db_path, "definitely not sqlite")

    Repo.reset!()
    Repo.delete_all(Message)
    Repo.delete_all(Session)
    kill_session_processes()

    on_exit(fn ->
      File.rm(@db_path)
      File.rm(@invalid_db_path)
      kill_session_processes()
    end)

    :ok
  end

  describe "list_sessions/2" do
    test "returns stripped ids and supports filtering and limit" do
      assert {:ok, sessions} =
               Importer.list_sessions(@db_path, directory: "C:/projects/app", limit: 1)

      assert [%{id: "01HSESSIONA", title: "Alpha chat", directory: "C:/projects/app"}] = sessions

      assert {:ok, [%{id: "01HSESSIONB"}]} =
               Importer.list_sessions(@db_path, search: "beta", limit: 5)
    end

    test "returns error when db is missing or invalid" do
      assert {:error, :db_not_found} =
               Importer.list_sessions(Path.join(@fixtures_dir, "missing.db"))

      assert {:error, :invalid_db} = Importer.list_sessions(@invalid_db_path)
    end
  end

  describe "import_session/2" do
    test "creates a local session and imports mapped messages" do
      assert {:ok, local_session_id} = Importer.import_session(@db_path, "session_01HSESSIONA")

      assert is_binary(local_session_id)
      assert {:ok, session} = Manager.get_session(local_session_id)
      assert session.channel == "opencode"
      assert session.channel_user_id == "01HSESSIONA"
      assert session.provider == "opencode"
      assert session.metadata["source"] == "opencode"
      assert session.metadata["source_session_id"] == "01HSESSIONA"
      assert session.metadata["directory"] == "C:/projects/app"

      imported_messages = Repo.list_session_messages(local_session_id)

      assert Enum.map(imported_messages, & &1.role) == ["user", "assistant"]

      assert Enum.map(imported_messages, & &1.content) == [
               "Hello importer",
               "Hi there\nGenerated code block\nsmall result"
             ]
    end
  end

  describe "import_messages/3" do
    test "appends only new messages since timestamp to an existing imported session" do
      assert {:ok, local_session_id} = Importer.import_session(@db_path, "session_01HSESSIONA")

      insert_source_message!(
        @db_path,
        "message_01HMSG003",
        "session_01HSESSIONA",
        1_700_000_000_300,
        %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Incremental hello"}]
        }
      )

      assert {:ok, 1} =
               Importer.import_messages(@db_path, "session_01HSESSIONA", since: 1_700_000_000_250)

      imported_messages = Repo.list_session_messages(local_session_id)

      assert Enum.map(imported_messages, & &1.content) == [
               "Hello importer",
               "Hi there\nGenerated code block\nsmall result",
               "Incremental hello"
             ]
    end
  end

  defp create_opencode_db!(path) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)

    try do
      :ok = Exqlite.Sqlite3.execute(conn, "DROP TABLE IF EXISTS parts")
      :ok = Exqlite.Sqlite3.execute(conn, "DROP TABLE IF EXISTS messages")
      :ok = Exqlite.Sqlite3.execute(conn, "DROP TABLE IF EXISTS sessions")

      :ok =
        Exqlite.Sqlite3.execute(
          conn,
          """
          CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            project_id TEXT,
            title TEXT,
            directory TEXT,
            time_created INTEGER,
            time_updated INTEGER,
            summary_diffs TEXT,
            parent_id TEXT
          )
          """
        )

      :ok =
        Exqlite.Sqlite3.execute(
          conn,
          """
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            time_created INTEGER,
            time_updated INTEGER,
            data TEXT NOT NULL
          )
          """
        )

      :ok =
        Exqlite.Sqlite3.execute(
          conn,
          """
          CREATE TABLE parts (
            id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            time_created INTEGER,
            data TEXT NOT NULL
          )
          """
        )

      insert_session!(
        conn,
        "session_01HSESSIONA",
        "Alpha chat",
        "C:/projects/app",
        1_700_000_000_000
      )

      insert_session!(
        conn,
        "session_01HSESSIONB",
        "Beta chat",
        "C:/projects/other",
        1_700_000_100_000
      )

      insert_message!(
        conn,
        "message_01HMSG001",
        "session_01HSESSIONA",
        1_700_000_000_100,
        %{
          "role" => "user",
          "content" => [%{"type" => "text", "text" => "Hello importer"}]
        }
      )

      insert_message!(
        conn,
        "message_01HMSG002",
        "session_01HSESSIONA",
        1_700_000_000_200,
        %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Hi there"}]
        }
      )

      insert_message!(
        conn,
        "message_01HMSG101",
        "session_01HSESSIONB",
        1_700_000_100_100,
        %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Beta result"}]
        }
      )

      insert_part!(
        conn,
        %{
          id: "part_01HPART001",
          message_id: "message_01HMSG002",
          session_id: "session_01HSESSIONA",
          timestamp: 1_700_000_000_201,
          data: %{"text" => "Generated code block"}
        }
      )

      insert_part!(
        conn,
        %{
          id: "part_01HPART002",
          message_id: "message_01HMSG002",
          session_id: "session_01HSESSIONA",
          timestamp: 1_700_000_000_202,
          data: %{"tool_results" => [%{"content" => "small result"}]}
        }
      )

      insert_part!(
        conn,
        %{
          id: "part_01HPART003",
          message_id: "message_01HMSG002",
          session_id: "session_01HSESSIONA",
          timestamp: 1_700_000_000_203,
          data: %{"tool_results" => [%{"content" => String.duplicate("x", 10_241)}]}
        }
      )
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  defp insert_source_message!(path, id, session_id, timestamp, data) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)

    try do
      insert_message!(conn, id, session_id, timestamp, data)
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  defp insert_session!(conn, id, title, directory, timestamp) do
    :ok =
      Exqlite.Sqlite3.execute(
        conn,
        """
        INSERT INTO sessions (id, project_id, title, directory, time_created, time_updated, summary_diffs, parent_id)
        VALUES (
          '#{sql(id)}',
          'project-main',
          '#{sql(title)}',
          '#{sql(directory)}',
          #{timestamp},
          #{timestamp + 10},
          '#{sql(Jason.encode!(%{"files" => []}))}',
          NULL
        )
        """
      )
  end

  defp insert_message!(conn, id, session_id, timestamp, data) do
    :ok =
      Exqlite.Sqlite3.execute(
        conn,
        """
        INSERT INTO messages (id, session_id, time_created, time_updated, data)
        VALUES (
          '#{sql(id)}',
          '#{sql(session_id)}',
          #{timestamp},
          #{timestamp + 1},
          '#{sql(Jason.encode!(data))}'
        )
        """
      )
  end

  defp insert_part!(conn, attrs) do
    %{id: id, message_id: message_id, session_id: session_id, timestamp: timestamp, data: data} =
      attrs

    :ok =
      Exqlite.Sqlite3.execute(
        conn,
        """
        INSERT INTO parts (id, message_id, session_id, time_created, data)
        VALUES (
          '#{sql(id)}',
          '#{sql(message_id)}',
          '#{sql(session_id)}',
          #{timestamp},
          '#{sql(Jason.encode!(data))}'
        )
        """
      )
  end

  defp sql(value) do
    value
    |> to_string()
    |> String.replace("'", "''")
  end

  defp kill_session_processes do
    for pid <- Registry.select(ElixirClaw.SessionRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}]) do
      _ = DynamicSupervisor.terminate_child(ElixirClaw.SessionSupervisor, pid)
    end
  catch
    :exit, _reason -> :ok
  end
end
