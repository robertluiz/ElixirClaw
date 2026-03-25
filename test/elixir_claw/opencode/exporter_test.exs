defmodule ElixirClaw.OpenCode.ExporterTest do
  use ExUnit.Case, async: false

  alias ElixirClaw.OpenCode.Exporter
  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.{Message, Session}
  alias ElixirClaw.Session.Manager
  alias ElixirClaw.Types.Message, as: SessionMessage

  setup do
    Repo.reset!()
    Repo.delete_all(Message)
    Repo.delete_all(Session)
    kill_session_processes()

    previous_api_url = Application.get_env(:elixir_claw, :opencode)
    previous_token = System.get_env("OPENCODE_CONSOLE_TOKEN")

    on_exit(fn ->
      if previous_api_url == nil do
        Application.delete_env(:elixir_claw, :opencode)
      else
        Application.put_env(:elixir_claw, :opencode, previous_api_url)
      end

      if previous_token == nil do
        System.delete_env("OPENCODE_CONSOLE_TOKEN")
      else
        System.put_env("OPENCODE_CONSOLE_TOKEN", previous_token)
      end

      kill_session_processes()
    end)

    :ok
  end

  describe "check_connection/1" do
    test "returns :ok when the API is reachable and authorized" do
      bypass = Bypass.open()
      configure_bypass(bypass)
      System.put_env("OPENCODE_CONSOLE_TOKEN", "secret-token")

      Bypass.expect_once(bypass, "GET", "/session", fn conn ->
        assert ["Bearer secret-token"] = Plug.Conn.get_req_header(conn, "authorization")
        assert conn.query_string == "limit=1"

        Plug.Conn.resp(conn, 200, Jason.encode!(%{"sessions" => []}))
      end)

      assert :ok = Exporter.check_connection()
    end

    test "returns unauthorized when the API rejects the token" do
      bypass = Bypass.open()
      configure_bypass(bypass)
      System.delete_env("OPENCODE_CONSOLE_TOKEN")

      Bypass.expect_once(bypass, "GET", "/session", fn conn ->
        assert ["Bearer"] = Plug.Conn.get_req_header(conn, "authorization")
        Plug.Conn.resp(conn, 401, "")
      end)

      assert {:error, :unauthorized} = Exporter.check_connection()
    end

    test "returns timeout when the API does not respond in time" do
      {server_pid, port} = start_hanging_server(150)
      Application.put_env(:elixir_claw, :opencode, api_url: "http://127.0.0.1:#{port}")

      on_exit(fn ->
        if Process.alive?(server_pid), do: Process.exit(server_pid, :kill)
      end)

      assert {:error, :timeout} = Exporter.check_connection(timeout: 20)
    end

    test "returns connection_refused when no server is listening" do
      {server_pid, port} = start_closing_server()
      Application.put_env(:elixir_claw, :opencode, api_url: "http://127.0.0.1:#{port}")

      on_exit(fn ->
        if Process.alive?(server_pid), do: Process.exit(server_pid, :kill)
      end)

      assert {:error, :connection_refused} = Exporter.check_connection(timeout: 200)
    end

    test "rejects invalid api_url values before connecting" do
      Application.put_env(:elixir_claw, :opencode, api_url: "localhost:3000")
      assert {:error, :invalid_api_url} = Exporter.check_connection()
    end
  end

  describe "push_message/3" do
    test "posts OpenCode-formatted message content and truncates oversized tool output" do
      bypass = Bypass.open()
      configure_bypass(bypass)
      System.put_env("OPENCODE_CONSOLE_TOKEN", "push-token")

      Bypass.expect_once(bypass, "POST", "/session/remote-123/message", fn conn ->
        assert ["Bearer push-token"] = Plug.Conn.get_req_header(conn, "authorization")
        assert ["application/json"] = Plug.Conn.get_req_header(conn, "content-type")

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert %{"role" => "tool", "content" => [%{"type" => "text", "text" => text}]} = request
        assert byte_size(text) <= 10_240
        assert text =~ "TRUNCATED"

        Plug.Conn.resp(conn, 201, Jason.encode!(%{"ok" => true}))
      end)

      message = %SessionMessage{role: "tool", content: String.duplicate("x", 10_500)}

      assert :ok = Exporter.push_message("remote-123", message)
    end

    test "returns http_error for unexpected response statuses" do
      bypass = Bypass.open()
      configure_bypass(bypass)

      Bypass.expect_once(bypass, "POST", "/session/remote-123/message", fn conn ->
        Plug.Conn.resp(conn, 500, "")
      end)

      message = %SessionMessage{role: "assistant", content: "hello"}

      assert {:error, {:http_error, 500}} = Exporter.push_message("remote-123", message)
    end
  end

  describe "export_session/2" do
    test "creates an OpenCode session then exports persisted messages in order" do
      bypass = Bypass.open()
      configure_bypass(bypass)
      System.put_env("OPENCODE_CONSOLE_TOKEN", "export-token")

      assert {:ok, session_id} =
               Manager.start_session(%{
                 channel: "cli",
                 channel_user_id: "export-user",
                 provider: "openai",
                 model: "gpt-4o-mini",
                 metadata: %{"locale" => "en"}
               })

      insert_message!(session_id, "user", "hello", ~N[2026-03-24 10:00:00])
      insert_message!(session_id, "assistant", "hi there", ~N[2026-03-24 10:00:01])

      parent = self()
      {:ok, request_count} = Agent.start_link(fn -> 0 end)

      Bypass.expect_once(bypass, "POST", "/session", fn conn ->
        assert ["Bearer export-token"] = Plug.Conn.get_req_header(conn, "authorization")
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert %{"title" => ^session_id, "directory" => "."} = Jason.decode!(body)

        Plug.Conn.resp(conn, 201, Jason.encode!(%{"id" => "remote-session-1"}))
      end)

      Bypass.stub(bypass, "POST", "/session/remote-session-1/message", fn conn ->
        Agent.update(request_count, &(&1 + 1))
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:exported_message, Jason.decode!(body)})
        Plug.Conn.resp(conn, 201, Jason.encode!(%{"ok" => true}))
      end)

      assert {:ok, %{opencode_session_id: "remote-session-1", messages_exported: 2}} =
               Exporter.export_session(session_id)

      assert_receive {:exported_message,
                      %{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]}}

      assert_receive {:exported_message,
                      %{
                        "role" => "assistant",
                        "content" => [%{"type" => "text", "text" => "hi there"}]
                      }}

      assert 2 == Agent.get(request_count, & &1)
    end

    test "returns not_found when the source session does not exist" do
      assert {:error, :not_found} = Exporter.export_session("missing-session")
    end

    test "propagates unauthorized when session creation fails with 401" do
      bypass = Bypass.open()
      configure_bypass(bypass)

      assert {:ok, session_id} =
               Manager.start_session(%{
                 channel: "cli",
                 channel_user_id: "unauthorized-user",
                 provider: "openai"
               })

      Bypass.expect_once(bypass, "POST", "/session", fn conn ->
        Plug.Conn.resp(conn, 401, "")
      end)

      assert {:error, :unauthorized} = Exporter.export_session(session_id)
    end
  end

  defp configure_bypass(bypass) do
    Application.put_env(:elixir_claw, :opencode, api_url: "http://localhost:#{bypass.port}")
  end

  defp insert_message!(session_id, role, content, inserted_at) do
    Repo.insert!(%Message{
      session_id: session_id,
      role: role,
      content: content,
      inserted_at: inserted_at
    })
  end

  defp kill_session_processes do
    for pid <- Registry.select(ElixirClaw.SessionRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}]) do
      _ = DynamicSupervisor.terminate_child(ElixirClaw.SessionSupervisor, pid)
    end
  catch
    :exit, _reason -> :ok
  end

  defp start_hanging_server(delay_ms) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listener)

    pid =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        Process.sleep(delay_ms)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    {pid, port}
  end

  defp start_closing_server do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listener)

    pid =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    {pid, port}
  end
end
