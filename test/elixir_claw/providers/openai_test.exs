defmodule ElixirClaw.Providers.OpenAITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ElixirClaw.Providers.OpenAI
  alias ElixirClaw.Types.{ProviderResponse, TokenUsage, ToolCall}

  setup do
    bypass = Bypass.open()
    previous_config = Application.get_env(:elixir_claw, OpenAI)

    Application.put_env(:elixir_claw, OpenAI,
      api_key: "sk-test-secret-key",
      base_url: "http://localhost:#{bypass.port}/v1",
      models: ["gpt-4o", "gpt-4o-mini"]
    )

    on_exit(fn ->
      if previous_config do
        Application.put_env(:elixir_claw, OpenAI, previous_config)
      else
        Application.delete_env(:elixir_claw, OpenAI)
      end
    end)

    %{bypass: bypass, api_key: "sk-test-secret-key"}
  end

  test "name/0 returns openai" do
    assert OpenAI.name() == "openai"
  end

  test "models/0 returns configured models" do
    assert OpenAI.models() == ["gpt-4o", "gpt-4o-mini"]
  end

  test "count_tokens/2 uses char heuristic" do
    assert OpenAI.count_tokens("abcdefghij", "gpt-4o") == {:ok, 3}
  end

  test "chat/2 returns provider response with content and token usage", %{bypass: bypass} do
    expect_chat_request(bypass, fn conn, body ->
      assert body["model"] == "gpt-4o"
      assert body["messages"] == [%{"role" => "user", "content" => "Hello"}]

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "id" => "chatcmpl_123",
          "model" => "gpt-4o",
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => "Hi there"},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{
            "prompt_tokens" => 11,
            "completion_tokens" => 7,
            "total_tokens" => 18
          }
        })
      )
    end)

    assert {:ok,
            %ProviderResponse{
              content: "Hi there",
              model: "gpt-4o",
              finish_reason: "stop",
              tool_calls: [],
              token_usage: %TokenUsage{input: 11, output: 7, total: 18}
            }} = OpenAI.chat([%{role: "user", content: "Hello"}], model: "gpt-4o")
  end

  test "chat/2 parses tool calls into ToolCall structs", %{bypass: bypass} do
    expect_chat_request(bypass, fn conn, _body ->
      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "model" => "gpt-4o",
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "content" => nil,
                "tool_calls" => [
                  %{
                    "id" => "call_1",
                    "type" => "function",
                    "function" => %{
                      "name" => "search_docs",
                      "arguments" => ~s({"query":"req_llm"})
                    }
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ],
          "usage" => %{"prompt_tokens" => 9, "completion_tokens" => 4, "total_tokens" => 13}
        })
      )
    end)

    assert {:ok, %ProviderResponse{tool_calls: [%ToolCall{} = tool_call]}} =
             OpenAI.chat([%{role: "user", content: "Search docs"}], tools: [%{type: "function"}])

    assert tool_call.id == "call_1"
    assert tool_call.name == "search_docs"
    assert tool_call.arguments == %{"query" => "req_llm"}
  end

  test "chat/2 normalizes empty tool calls to []", %{bypass: bypass} do
    expect_chat_request(bypass, fn conn, _body ->
      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "model" => "gpt-4o",
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => "done", "tool_calls" => []},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 1, "total_tokens" => 3}
        })
      )
    end)

    assert {:ok, %ProviderResponse{tool_calls: []}} =
             OpenAI.chat([%{role: "user", content: "Done?"}])
  end

  test "stream/2 returns chunks with delta text and final usage", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["stream"] == true
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-test-secret-key"]

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          "data: " <>
            Jason.encode!(%{
              "choices" => [%{"delta" => %{"content" => "Hel"}, "finish_reason" => nil}]
            }) <> "\n\n"
        )

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          "data: " <>
            Jason.encode!(%{
              "choices" => [%{"delta" => %{"content" => "lo"}, "finish_reason" => nil}]
            }) <> "\n\n"
        )

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          "data: " <>
            Jason.encode!(%{
              "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}],
              "usage" => %{"prompt_tokens" => 6, "completion_tokens" => 2, "total_tokens" => 8}
            }) <> "\n\n"
        )

      {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
      conn
    end)

    assert {:ok, stream} = OpenAI.stream([%{role: "user", content: "Hello"}], model: "gpt-4o")

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

  test "invalid API key returns unauthorized and never logs the secret", %{bypass: bypass, api_key: api_key} do
    expect_chat_request(bypass, fn conn, _body ->
      Plug.Conn.resp(
        conn,
        401,
        Jason.encode!(%{
          "error" => %{
            "message" => "Incorrect API key provided: #{api_key}",
            "type" => "invalid_request_error"
          }
        })
      )
    end)

    log =
      capture_log(fn ->
        assert OpenAI.chat([%{role: "user", content: "Hello"}]) == {:error, :unauthorized}
      end)

    refute log =~ api_key
  end

  test "server error is sanitized", %{bypass: bypass} do
    expect_chat_request(bypass, fn conn, _body ->
      Plug.Conn.resp(
        conn,
        500,
        Jason.encode!(%{"error" => %{"message" => "upstream exploded", "type" => "server_error"}})
      )
    end)

    assert OpenAI.chat([%{role: "user", content: "Hello"}]) == {:error, :server_error}
  end

  defp expect_chat_request(bypass, fun) do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-test-secret-key"]
      assert ["application/json"] = Plug.Conn.get_req_header(conn, "content-type")
      fun.(conn, Jason.decode!(body))
    end)
  end
end
