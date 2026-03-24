defmodule ElixirClaw.MCP.HTTPClientTest do
  use ExUnit.Case, async: false

  alias ElixirClaw.MCP.HTTPClient

  setup do
    bypass = Bypass.open()

    {:ok, requests} =
      Agent.start_link(fn -> %{initialize: 0, initialized: 0, list_tools: 0, call_tool: 0} end)

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      case request do
        %{"method" => "initialize", "id" => id} ->
          Agent.update(requests, &Map.update!(&1, :initialize, fn count -> count + 1 end))

          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.put_resp_header("mcp-session-id", "session-123")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "protocolVersion" => "2025-03-26",
                "capabilities" => %{"tools" => %{}},
                "serverInfo" => %{"name" => "Bypass MCP", "version" => "1.0.0"}
              }
            })
          )

        %{"method" => "notifications/initialized"} ->
          Agent.update(requests, &Map.update!(&1, :initialized, fn count -> count + 1 end))
          Plug.Conn.resp(conn, 202, "")

        %{"method" => "tools/list", "id" => id} ->
          Agent.update(requests, &Map.update!(&1, :list_tools, fn count -> count + 1 end))

          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.put_resp_header("mcp-session-id", "session-123")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "tools" => [
                  %{
                    "name" => "echo",
                    "description" => "Echo text",
                    "inputSchema" => %{
                      "type" => "object",
                      "properties" => %{"text" => %{"type" => "string"}},
                      "required" => ["text"]
                    }
                  }
                ]
              }
            })
          )

        %{
          "method" => "tools/call",
          "params" => %{"name" => "echo", "arguments" => %{"text" => text}},
          "id" => id
        } ->
          Agent.update(requests, &Map.update!(&1, :call_tool, fn count -> count + 1 end))

          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.put_resp_header("mcp-session-id", "session-123")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "content" => [
                  %{"type" => "text", "text" => text}
                ],
                "isError" => false
              }
            })
          )

        %{"method" => "tools/call", "params" => %{"name" => "large"}, "id" => id} ->
          Agent.update(requests, &Map.update!(&1, :call_tool, fn count -> count + 1 end))

          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.put_resp_header("mcp-session-id", "session-123")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "content" => [
                  %{"type" => "text", "text" => String.duplicate("a", 70_000)}
                ],
                "isError" => false
              }
            })
          )

        %{"method" => "tools/call", "params" => %{"name" => "slow"}, "id" => id} ->
          Agent.update(requests, &Map.update!(&1, :call_tool, fn count -> count + 1 end))
          Process.sleep(75)

          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.put_resp_header("mcp-session-id", "session-123")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "content" => [
                  %{"type" => "text", "text" => "too late"}
                ],
                "isError" => false
              }
            })
          )

        other ->
          flunk("unexpected MCP request: #{inspect(other)}")
      end
    end)

    {:ok, bypass: bypass, requests: requests}
  end

  describe "connect/1" do
    test "connects to a localhost MCP endpoint and completes the handshake", %{
      bypass: bypass,
      requests: requests
    } do
      assert {:ok, client} = HTTPClient.connect(url: bypass_url(bypass))

      eventually(fn ->
        assert %{initialize: 1, initialized: 1} = Agent.get(requests, & &1)
      end)

      assert :ok = HTTPClient.disconnect(client)
    end

    test "rejects insecure remote HTTP URLs" do
      assert {:error, :insecure_transport} = HTTPClient.connect(url: "http://example.com/mcp")
    end
  end

  describe "list_tools/1" do
    test "returns normalized tools and caches the first successful response", %{
      bypass: bypass,
      requests: requests
    } do
      {:ok, client} = HTTPClient.connect(url: bypass_url(bypass))

      assert [
               %{
                 name: "echo",
                 description: "Echo text",
                 schema: %{"required" => ["text"], "type" => "object"}
               }
             ] = HTTPClient.list_tools(client)

      assert [%{name: "echo"}] = HTTPClient.list_tools(client)

      eventually(fn ->
        assert %{list_tools: 1} = Agent.get(requests, & &1)
      end)

      assert :ok = HTTPClient.disconnect(client)
    end
  end

  describe "call_tool/3" do
    test "returns text tool output", %{bypass: bypass} do
      {:ok, client} = HTTPClient.connect(url: bypass_url(bypass))

      assert {:ok, "hello"} = HTTPClient.call_tool(client, "echo", %{"text" => "hello"})
      assert :ok = HTTPClient.disconnect(client)
    end

    test "truncates tool output at 64KB and appends a marker", %{bypass: bypass} do
      {:ok, client} = HTTPClient.connect(url: bypass_url(bypass))

      assert {:ok, output} = HTTPClient.call_tool(client, "large", %{})
      assert output == String.duplicate("a", 65_536) <> "[OUTPUT TRUNCATED at 64KB]"

      assert :ok = HTTPClient.disconnect(client)
    end

    test "returns timeout when the underlying Hermes call takes too long", %{bypass: bypass} do
      previous = Process.flag(:trap_exit, true)
      {:ok, client} = HTTPClient.connect(url: bypass_url(bypass), timeout: 20)

      assert {:error, :timeout} = HTTPClient.call_tool(client, "slow", %{})

      Process.sleep(100)
      assert :ok = HTTPClient.disconnect(client)

      Process.flag(:trap_exit, previous)
    end
  end

  test "disconnect/1 stops the client process", %{bypass: bypass} do
    {:ok, client} = HTTPClient.connect(url: bypass_url(bypass))
    monitor = Process.monitor(client)

    assert :ok = HTTPClient.disconnect(client)
    assert_receive {:DOWN, ^monitor, :process, ^client, _reason}, 1_000
  end

  defp bypass_url(bypass), do: "http://localhost:#{bypass.port}/mcp"

  defp eventually(fun, attempts \\ 25)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    fun.()
  rescue
    error in [ExUnit.AssertionError] ->
      Process.sleep(20)

      try do
        eventually(fun, attempts - 1)
      rescue
        _ -> reraise error, __STACKTRACE__
      end
  end
end
