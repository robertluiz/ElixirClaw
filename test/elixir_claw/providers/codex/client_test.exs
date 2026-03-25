defmodule ElixirClaw.Providers.Codex.ClientTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ElixirClaw.Providers.Codex.{Client, TokenManager}
  alias ElixirClaw.Types.{ProviderResponse, TokenUsage, ToolCall}

  setup do
    bypass = Bypass.open()
    previous_config = Application.get_env(:elixir_claw, Client)

    Application.put_env(:elixir_claw, Client,
      account_id: "acct-test-secret",
      base_url: "http://localhost:#{bypass.port}",
      models: ["codex-mini", "codex-pro"]
    )

    assert :ok = TokenManager.clear_token()

    assert :ok =
             TokenManager.store_token(%{
               access_token: "codex-access-token",
               refresh_token: "codex-refresh-token",
               expires_in: 3600
             })

    on_exit(fn ->
      assert :ok = TokenManager.clear_token()

      if previous_config do
        Application.put_env(:elixir_claw, Client, previous_config)
      else
        Application.delete_env(:elixir_claw, Client)
      end
    end)

    %{bypass: bypass, access_token: "codex-access-token", account_id: "acct-test-secret"}
  end

  test "name/0 returns codex" do
    assert Client.name() == "codex"
  end

  test "models/0 returns configured models" do
    assert Client.models() == ["codex-mini", "codex-pro"]
  end

  test "models/0 defaults to codex-mini when config omits models", %{bypass: bypass} do
    Application.put_env(:elixir_claw, Client,
      account_id: "acct-test-secret",
      base_url: "http://localhost:#{bypass.port}"
    )

    assert Client.models() == ["codex-mini"]
  end

  test "count_tokens/2 uses char heuristic" do
    assert Client.count_tokens("abcdefghij", "codex-mini") == {:ok, 3}
  end

  test "chat/2 sends Codex request format and parses output items", %{bypass: bypass} do
    tools = [
      %{
        type: "function",
        function: %{
          name: "search_docs",
          description: "Search docs",
          parameters: %{"type" => "object", "properties" => %{"query" => %{"type" => "string"}}}
        }
      }
    ]

    messages = [
      %{role: "system", content: "You are concise"},
      %{role: "user", content: "Search req_llm"},
      %{
        role: "assistant",
        content: "Let me search",
        tool_calls: [
          %ToolCall{
            id: "call_search|fc_search",
            name: "search_docs",
            arguments: %{"query" => "req_llm"}
          }
        ]
      },
      %{role: "tool", tool_call_id: "call_search|fc_search", content: "Docs found"}
    ]

    expect_responses_request(bypass, fn conn, body ->
      assert body["model"] == "codex-mini"
      assert body["instructions"] == "You are concise"
      assert body["stream"] == false
      assert body["previous_response_id"] == "resp_previous"

      assert body["input"] == [
               %{
                 "role" => "user",
                 "content" => [%{"type" => "input_text", "text" => "Search req_llm"}]
               },
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [%{"type" => "output_text", "text" => "Let me search"}],
                 "status" => "completed"
               },
               %{
                 "type" => "function_call",
                 "id" => "fc_search",
                 "call_id" => "call_search",
                 "name" => "search_docs",
                 "arguments" => Jason.encode!(%{"query" => "req_llm"})
               },
               %{
                 "type" => "function_call_output",
                 "call_id" => "call_search",
                 "output" => "Docs found"
               }
             ]

      assert body["tools"] == [
               %{
                 "type" => "function",
                 "name" => "search_docs",
                 "description" => "Search docs",
                 "parameters" => %{
                   "type" => "object",
                   "properties" => %{"query" => %{"type" => "string"}}
                 }
               }
             ]

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "id" => "resp_123",
          "model" => "codex-mini",
          "status" => "completed",
          "output" => [
            %{
              "type" => "message",
              "content" => [
                %{"type" => "output_text", "text" => "I'll search that."}
              ]
            },
            %{
              "type" => "function_call",
              "id" => "fc_1",
              "call_id" => "call_1",
              "name" => "search_docs",
              "arguments" => ~s({"query":"req_llm"})
            }
          ],
          "usage" => %{"input_tokens" => 12, "output_tokens" => 7, "total_tokens" => 19}
        })
      )
    end)

    assert {:ok,
            %ProviderResponse{
              content: "I'll search that.",
              model: "codex-mini",
              finish_reason: "completed",
              token_usage: %TokenUsage{input: 12, output: 7, total: 19},
              tool_calls: [
                %ToolCall{
                  id: "call_1|fc_1",
                  name: "search_docs",
                  arguments: %{"query" => "req_llm"}
                }
              ]
            }} =
             Client.chat(messages,
               model: "codex-mini",
               previous_response_id: "resp_previous",
               tools: tools
             )
  end

  test "stream/2 emits text deltas and final usage from named sse events", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/backend-api/codex/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["model"] == "codex-mini"
      assert request["stream"] == true
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer codex-access-token"]
      assert Plug.Conn.get_req_header(conn, "chatgpt-account-id") == ["acct-test-secret"]

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          sse_event("response.created", %{
            "response" => %{"id" => "resp_123", "model" => "codex-mini"}
          })
        )

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          sse_event("response.output_item.added", %{
            "item" => %{"type" => "message", "id" => "msg_1"}
          })
        )

      {:ok, conn} =
        Plug.Conn.chunk(conn, sse_event("response.content_part.delta", %{"delta" => "Hel"}))

      {:ok, conn} =
        Plug.Conn.chunk(conn, sse_event("response.content_part.delta", %{"delta" => "lo"}))

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          sse_event("response.output_item.done", %{
            "item" => %{"type" => "message", "id" => "msg_1"}
          })
        )

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          sse_event("response.completed", %{
            "response" => %{
              "status" => "completed",
              "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
            }
          })
        )

      conn
    end)

    assert {:ok, stream} = Client.stream([%{role: "user", content: "Hello"}], model: "codex-mini")

    assert [first, second, final] = Enum.to_list(stream)
    assert first == %{delta: "Hel", finish_reason: nil, tool_calls: [], token_usage: nil}
    assert second == %{delta: "lo", finish_reason: nil, tool_calls: [], token_usage: nil}

    assert final == %{
             delta: "",
             finish_reason: :stop,
             tool_calls: [],
             token_usage: %TokenUsage{input: 6, output: 2, total: 8}
           }
  end

  test "stream/2 normalizes function_call output items into ToolCall structs", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/backend-api/codex/responses", fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          sse_event("response.output_item.added", %{
            "item" => %{
              "type" => "function_call",
              "id" => "fc_stream_1",
              "call_id" => "call_stream_1",
              "name" => "search_docs",
              "arguments" => ""
            }
          })
        )

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          sse_event("response.output_item.done", %{
            "item" => %{
              "type" => "function_call",
              "id" => "fc_stream_1",
              "call_id" => "call_stream_1",
              "name" => "search_docs",
              "arguments" => ~s({"query":"req_llm"})
            }
          })
        )

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          sse_event("response.completed", %{
            "response" => %{
              "status" => "completed",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 3, "total_tokens" => 13}
            }
          })
        )

      conn
    end)

    assert {:ok, stream} =
             Client.stream([%{role: "user", content: "Search docs"}],
               model: "codex-mini",
               tools: [%{type: "function", function: %{name: "search_docs", parameters: %{}}}]
             )

    assert [final] = Enum.to_list(stream)

    assert final == %{
             delta: "",
             finish_reason: :tool_calls,
             tool_calls: [
               %ToolCall{
                 id: "call_stream_1|fc_stream_1",
                 name: "search_docs",
                 arguments: %{"query" => "req_llm"}
               }
             ],
             token_usage: %TokenUsage{input: 10, output: 3, total: 13}
           }
  end

  test "missing token returns no_token without making a request" do
    assert :ok = TokenManager.clear_token()
    assert Client.chat([%{role: "user", content: "Hello"}]) == {:error, :no_token}
  end

  test "unauthorized responses are sanitized and never log secrets", %{
    bypass: bypass,
    access_token: access_token,
    account_id: account_id
  } do
    expect_responses_request(bypass, fn conn, _body ->
      Plug.Conn.resp(
        conn,
        401,
        Jason.encode!(%{
          "error" => %{
            "message" => "token #{access_token} account #{account_id} is invalid"
          }
        })
      )
    end)

    log =
      capture_log(fn ->
        assert Client.chat([%{role: "user", content: "Hello"}]) == {:error, :unauthorized}
      end)

    refute log =~ access_token
    refute log =~ account_id
  end

  test "server errors are sanitized", %{bypass: bypass} do
    expect_responses_request(bypass, fn conn, _body ->
      Plug.Conn.resp(conn, 500, Jason.encode!(%{"error" => %{"message" => "boom"}}))
    end)

    assert Client.chat([%{role: "user", content: "Hello"}]) == {:error, :server_error}
  end

  test "client errors are sanitized to request_failed", %{bypass: bypass} do
    expect_responses_request(bypass, fn conn, _body ->
      Plug.Conn.resp(conn, 400, Jason.encode!(%{"error" => %{"message" => "bad request"}}))
    end)

    assert Client.chat([%{role: "user", content: "Hello"}]) == {:error, :request_failed}
  end

  defp expect_responses_request(bypass, fun) do
    Bypass.expect_once(bypass, "POST", "/backend-api/codex/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer codex-access-token"]
      assert Plug.Conn.get_req_header(conn, "chatgpt-account-id") == ["acct-test-secret"]
      assert ["application/json"] = Plug.Conn.get_req_header(conn, "content-type")
      fun.(conn, Jason.decode!(body))
    end)
  end

  defp sse_event(type, payload) do
    "event: #{type}\ndata: #{Jason.encode!(payload)}\n\n"
  end
end
