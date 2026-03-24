defmodule ElixirClaw.MCP.StdioClientTest do
  use ExUnit.Case, async: false

  alias ElixirClaw.MCP.StdioClient

  @truncation_marker "[OUTPUT TRUNCATED at 64KB]"

  describe "start_link/1" do
    test "opens the configured executable with secure Port options" do
      parent = self()
      fake_port = make_ref()
      executable = fixture_executable()

      assert {:ok, pid} =
               StdioClient.start_link(
                 command: [executable, "--stdio", "--verbose"],
                 cwd: "C:/tools",
                 env: [{"NODE_ENV", "test"}],
                 port_open_fn: fn spec, options ->
                   send(parent, {:port_open, spec, options})
                   {:ok, fake_port}
                 end,
                 send_fn: fn _port, _payload -> :ok end,
                 port_close_fn: fn _port -> :ok end
               )

      assert_receive {:port_open, {:spawn_executable, ^executable}, options}
      assert :binary in options
      assert :exit_status in options
      assert {:line, 65_536} in options
      assert Keyword.fetch!(options, :args) == ["--stdio", "--verbose"]
      assert Keyword.fetch!(options, :cd) == "C:/tools"
      assert Keyword.fetch!(options, :env) == [{~c"NODE_ENV", ~c"test"}]

      assert :ok = StdioClient.stop(pid)
    end

    test "returns command_not_found when the executable cannot be resolved" do
      assert {:error, :command_not_found} =
               StdioClient.start_link(command: ["definitely-not-a-real-executable-12345"])
    end
  end

  describe "list_tools/1" do
    test "sends a JSON-RPC tools/list request and maps the response" do
      {pid, fake_port} = start_client()

      task = Task.async(fn -> StdioClient.list_tools(pid) end)

      assert_receive {:port_command, ^fake_port, payload}
      assert String.ends_with?(payload, "\n")

      request = decode_line(payload)
      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "tools/list"
      assert request["params"] == %{}
      assert is_integer(request["id"])

      send(
        pid,
        {fake_port,
         {:data,
          {:eol,
           Jason.encode!(%{
             "jsonrpc" => "2.0",
             "id" => request["id"],
             "result" => %{
               "tools" => [
                 %{
                   "name" => "search_docs",
                   "description" => "Search project docs",
                   "inputSchema" => %{"type" => "object", "properties" => %{}}
                 }
               ]
             }
           })}}}
      )

      assert Task.await(task) ==
               {:ok,
                [
                  %{
                    name: "search_docs",
                    description: "Search project docs",
                    schema: %{"type" => "object", "properties" => %{}}
                  }
                ]}

      assert :ok = StdioClient.stop(pid)
    end

    test "returns timeout when a response never arrives" do
      {pid, _fake_port} = start_client(timeout_ms: 10)

      assert {:error, :timeout} = StdioClient.list_tools(pid)

      assert :ok = StdioClient.stop(pid)
    end
  end

  describe "call_tool/3" do
    test "extracts text content and truncates oversized output" do
      {pid, fake_port} = start_client()

      task = Task.async(fn -> StdioClient.call_tool(pid, "search_docs", %{"query" => "otp"}) end)

      assert_receive {:port_command, ^fake_port, payload}
      request = decode_line(payload)

      assert request["method"] == "tools/call"
      assert request["params"] == %{"name" => "search_docs", "arguments" => %{"query" => "otp"}}

      oversized_text = String.duplicate("x", 65_540)

      send(
        pid,
        {fake_port,
         {:data,
          {:eol,
           Jason.encode!(%{
             "jsonrpc" => "2.0",
             "id" => request["id"],
             "result" => %{
               "content" => [
                 %{"type" => "text", "text" => oversized_text}
               ]
             }
           })}}}
      )

      assert {:ok, result} = Task.await(task)
      assert String.starts_with?(result, String.duplicate("x", 65_536))
      assert String.ends_with?(result, @truncation_marker)

      assert :ok = StdioClient.stop(pid)
    end

    test "returns process_exited when the port exits before replying" do
      previous_trap_exit = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)

      {pid, fake_port} = start_client()

      task = Task.async(fn -> StdioClient.call_tool(pid, "search_docs", %{}) end)

      assert_receive {:port_command, ^fake_port, _payload}

      ref = Process.monitor(pid)
      send(pid, {fake_port, {:exit_status, 1}})

      assert Task.await(task) == {:error, :process_exited}
      assert_receive {:DOWN, ^ref, :process, ^pid, :process_exited}
    end
  end

  describe "stop/1" do
    test "closes the port and terminates the GenServer" do
      parent = self()
      fake_port = make_ref()
      executable = fixture_executable()

      assert {:ok, pid} =
               StdioClient.start_link(
                 command: [executable],
                 port_open_fn: fn _spec, _options -> {:ok, fake_port} end,
                 send_fn: fn _port, _payload -> :ok end,
                 port_close_fn: fn port ->
                   send(parent, {:port_closed, port})
                   :ok
                 end
               )

      ref = Process.monitor(pid)

      assert :ok = StdioClient.stop(pid)
      assert_receive {:port_closed, ^fake_port}
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end
  end

  defp start_client(overrides \\ []) do
    parent = self()
    fake_port = make_ref()
    executable = fixture_executable()

    opts =
      Keyword.merge(
        [
          command: [executable, "--stdio"],
          timeout_ms: 100,
          port_open_fn: fn spec, options ->
            send(parent, {:port_open, spec, options})
            {:ok, fake_port}
          end,
          send_fn: fn port, payload ->
            send(parent, {:port_command, port, payload})
            :ok
          end,
          port_close_fn: fn _port -> :ok end
        ],
        overrides
      )

    assert {:ok, pid} = StdioClient.start_link(opts)
    assert_receive {:port_open, {:spawn_executable, ^executable}, _options}
    {pid, fake_port}
  end

  defp decode_line(payload) do
    payload
    |> String.trim_trailing("\n")
    |> Jason.decode!()
  end

  defp fixture_executable do
    System.find_executable("cmd") || raise "expected cmd executable on Windows test host"
  end
end
