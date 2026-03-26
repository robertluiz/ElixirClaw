defmodule ElixirClaw.Providers.AnthropicTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ElixirClaw.Providers.Anthropic
  alias ElixirClaw.Types.{ProviderResponse, TokenUsage, ToolCall}

  setup do
    bypass = Bypass.open()
    previous_config = Application.get_env(:elixir_claw, Anthropic)

    Application.put_env(:elixir_claw, Anthropic,
      api_key: "sk-ant-test-secret-key",
      base_url: "http://localhost:#{bypass.port}/v1",
      anthropic_version: "2023-06-01",
      models: ["claude-3-5-sonnet", "claude-3-5-haiku"]
    )

    on_exit(fn ->
      if previous_config do
        Application.put_env(:elixir_claw, Anthropic, previous_config)
      else
        Application.delete_env(:elixir_claw, Anthropic)
      end
    end)

    %{bypass: bypass, api_key: "sk-ant-test-secret-key"}
  end

  test "name/0 returns anthropic" do
    assert Anthropic.name() == "anthropic"
  end

  test "models/0 returns configured models" do
    assert Anthropic.models() == ["claude-3-5-sonnet", "claude-3-5-haiku"]
  end

  test "count_tokens/2 uses char heuristic" do
    assert Anthropic.count_tokens("abcdefghij", "claude-3-5-sonnet") == {:ok, 3}
  end

  test "chat/2 sends anthropic headers, system prompt, tool results, and parses token usage", %{
    bypass: bypass
  } do
    expect_messages_request(bypass, fn conn, body ->
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["sk-ant-test-secret-key"]
      assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]
      assert body["model"] == "claude-3-5-sonnet"
      assert body["system"] == "Be helpful"
      assert body["max_tokens"] == 4096

      assert body["messages"] == [
               %{"role" => "user", "content" => "What's the weather?"},
               %{
                 "role" => "assistant",
                 "content" => [
                   %{
                     "type" => "tool_use",
                     "id" => "toolu_123",
                     "name" => "get_weather",
                     "input" => %{"city" => "Paris"}
                   }
                 ]
               },
               %{
                 "role" => "user",
                 "content" => [
                   %{
                     "type" => "tool_result",
                     "tool_use_id" => "toolu_123",
                     "content" => "Sunny"
                   }
                 ]
               }
             ]

      assert body["tools"] == [
               %{
                 "name" => "get_weather",
                 "description" => "Fetch weather",
                 "input_schema" => %{"type" => "object"}
               }
             ]

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "id" => "msg_123",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-3-5-sonnet",
          "stop_reason" => "end_turn",
          "content" => [%{"type" => "text", "text" => "It is sunny."}],
          "usage" => %{"input_tokens" => 12, "output_tokens" => 8}
        })
      )
    end)

    messages = [
      %{role: "system", content: "Be helpful"},
      %{role: "user", content: "What's the weather?"},
      %{
        role: "assistant",
        content: "",
        tool_calls: [
          %ToolCall{id: "toolu_123", name: "get_weather", arguments: %{"city" => "Paris"}}
        ]
      },
      %{role: "tool", tool_call_id: "toolu_123", content: "Sunny"}
    ]

    tools = [
      %{
        "name" => "get_weather",
        "description" => "Fetch weather",
        "input_schema" => %{"type" => "object"}
      }
    ]

    assert {:ok,
            %ProviderResponse{
              content: "It is sunny.",
              tool_calls: [],
              model: "claude-3-5-sonnet",
              finish_reason: "end_turn",
              token_usage: %TokenUsage{input: 12, output: 8, total: 20}
            }} = Anthropic.chat(messages, model: "claude-3-5-sonnet", tools: tools)
  end

  test "chat/2 parses tool_use content blocks into ToolCall structs", %{bypass: bypass} do
    expect_messages_request(bypass, fn conn, _body ->
      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "model" => "claude-3-5-sonnet",
          "stop_reason" => "tool_use",
          "content" => [
            %{"type" => "text", "text" => "Let me check."},
            %{
              "type" => "tool_use",
              "id" => "toolu_456",
              "name" => "search_docs",
              "input" => %{"query" => "req_llm"}
            }
          ],
          "usage" => %{"input_tokens" => 9, "output_tokens" => 4}
        })
      )
    end)

    assert {:ok,
            %ProviderResponse{content: "Let me check.", tool_calls: [%ToolCall{} = tool_call]}} =
             Anthropic.chat([%{role: "user", content: "Search docs"}],
               tools: [%{"name" => "search_docs"}]
             )

    assert tool_call.id == "toolu_456"
    assert tool_call.name == "search_docs"
    assert tool_call.arguments == %{"query" => "req_llm"}
  end

  test "chat/2 forwards thinking config with max_tokens", %{bypass: bypass} do
    expect_messages_request(bypass, fn conn, body ->
      assert body["model"] == "claude-sonnet-4-20250514"
      assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => 4_000}
      assert body["max_tokens"] == 8_000

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "model" => "claude-sonnet-4-20250514",
          "stop_reason" => "end_turn",
          "content" => [%{"type" => "text", "text" => "Thoughtful reply"}],
          "usage" => %{"input_tokens" => 9, "output_tokens" => 5}
        })
      )
    end)

    assert {:ok, %ProviderResponse{content: "Thoughtful reply"}} =
             Anthropic.chat([%{role: "user", content: "Hello"}],
               model: "claude-sonnet-4-20250514",
               thinking: %{"type" => "enabled", "budget_tokens" => 4_000},
               max_tokens: 8_000
             )
  end

  test "chat/2 defaults max_tokens when none is provided", %{bypass: bypass} do
    expect_messages_request(bypass, fn conn, body ->
      assert body["model"] == "claude-3-5-sonnet"
      assert body["max_tokens"] == 4096

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "model" => "claude-3-5-sonnet",
          "stop_reason" => "end_turn",
          "content" => [%{"type" => "text", "text" => "Default max tokens"}],
          "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
        })
      )
    end)

    assert {:ok, %ProviderResponse{content: "Default max tokens"}} =
             Anthropic.chat([%{role: "user", content: "Hello"}], model: "claude-3-5-sonnet")
  end

  test "chat/2 uses default anthropic-version header when config omits one", %{bypass: bypass} do
    Application.put_env(:elixir_claw, Anthropic,
      api_key: "sk-ant-test-secret-key",
      base_url: "http://localhost:#{bypass.port}/v1",
      models: ["claude-3-5-sonnet"]
    )

    expect_messages_request(bypass, fn conn, _body ->
      assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "model" => "claude-3-5-sonnet",
          "stop_reason" => "end_turn",
          "content" => [%{"type" => "text", "text" => "ok"}],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        })
      )
    end)

    assert {:ok, %ProviderResponse{content: "ok"}} =
             Anthropic.chat([%{role: "user", content: "Hello"}])
  end

  test "stream/2 returns text deltas and final usage from anthropic sse events", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["stream"] == true
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["sk-ant-test-secret-key"]
      assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          sse_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 6}}
          })
        )

      {:ok, conn} = Plug.Conn.chunk(conn, sse_event("content_block_start", %{"index" => 0}))
      {:ok, conn} = Plug.Conn.chunk(conn, sse_event("content_block_delta", text_delta("Hel")))
      {:ok, conn} = Plug.Conn.chunk(conn, sse_event("content_block_delta", text_delta("lo")))
      {:ok, conn} = Plug.Conn.chunk(conn, sse_event("content_block_stop", %{"index" => 0}))

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          sse_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 2}
          })
        )

      {:ok, conn} = Plug.Conn.chunk(conn, sse_event("message_stop", %{}))
      conn
    end)

    assert {:ok, stream} =
             Anthropic.stream([%{role: "user", content: "Hello"}], model: "claude-3-5-sonnet")

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

  test "stream/2 assembles streamed tool_use blocks", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          sse_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 10}}
          })
        )

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          sse_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "toolu_stream_1",
              "name" => "search_docs",
              "input" => %{}
            }
          })
        )

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          sse_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"query":")}
          })
        )

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          sse_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => ~s(req_llm"})}
          })
        )

      {:ok, conn} = Plug.Conn.chunk(conn, sse_event("content_block_stop", %{"index" => 0}))

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          sse_event("message_delta", %{
            "delta" => %{"stop_reason" => "tool_use"},
            "usage" => %{"output_tokens" => 3}
          })
        )

      {:ok, conn} = Plug.Conn.chunk(conn, sse_event("message_stop", %{}))
      conn
    end)

    assert {:ok, stream} =
             Anthropic.stream([%{role: "user", content: "Search docs"}],
               tools: [%{"name" => "search_docs"}]
             )

    assert [final] = Enum.to_list(stream)

    assert final == %{
             delta: "",
             finish_reason: :tool_calls,
             tool_calls: [
               %ToolCall{
                 id: "toolu_stream_1",
                 name: "search_docs",
                 arguments: %{"query" => "req_llm"}
               }
             ],
             token_usage: %TokenUsage{input: 10, output: 3, total: 13}
           }
  end

  test "invalid api key returns unauthorized and never logs the secret", %{
    bypass: bypass,
    api_key: api_key
  } do
    expect_messages_request(bypass, fn conn, _body ->
      Plug.Conn.resp(
        conn,
        401,
        Jason.encode!(%{
          "error" => %{
            "type" => "authentication_error",
            "message" => "invalid x-api-key #{api_key}"
          }
        })
      )
    end)

    log =
      capture_log(fn ->
        assert Anthropic.chat([%{role: "user", content: "Hello"}]) == {:error, :unauthorized}
      end)

    refute log =~ api_key
  end

  test "server errors are sanitized", %{bypass: bypass} do
    expect_messages_request(bypass, fn conn, _body ->
      Plug.Conn.resp(
        conn,
        500,
        Jason.encode!(%{"error" => %{"message" => "internal stack trace: boom"}})
      )
    end)

    assert Anthropic.chat([%{role: "user", content: "Hello"}]) == {:error, :server_error}
  end

  defp expect_messages_request(bypass, fun) do
    Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert ["application/json"] = Plug.Conn.get_req_header(conn, "content-type")
      fun.(conn, Jason.decode!(body))
    end)
  end

  defp sse_event(type, payload) do
    "event: #{type}\ndata: #{Jason.encode!(payload)}\n\n"
  end

  defp text_delta(text) do
    %{
      "index" => 0,
      "delta" => %{"type" => "text_delta", "text" => text}
    }
  end
end
