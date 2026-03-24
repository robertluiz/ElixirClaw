defmodule ElixirClaw.Providers.CopilotBYOKTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ElixirClaw.Providers.CopilotBYOK
  alias ElixirClaw.Types.{ProviderResponse, TokenUsage, ToolCall}

  setup do
    bypass = Bypass.open()
    previous_config = Application.get_env(:elixir_claw, CopilotBYOK)

    Application.put_env(:elixir_claw, CopilotBYOK,
      api_key: "copilot-test-secret-key",
      base_url: "http://localhost:#{bypass.port}/custom/v1",
      models: ["gpt-4o-mini"]
    )

    on_exit(fn ->
      if previous_config do
        Application.put_env(:elixir_claw, CopilotBYOK, previous_config)
      else
        Application.delete_env(:elixir_claw, CopilotBYOK)
      end
    end)

    %{bypass: bypass, api_key: "copilot-test-secret-key"}
  end

  test "name/0 returns copilot_byok" do
    assert CopilotBYOK.name() == "copilot_byok"
  end

  test "models/0 returns configured models" do
    assert CopilotBYOK.models() == ["gpt-4o-mini"]
  end

  test "count_tokens/2 uses char heuristic" do
    assert CopilotBYOK.count_tokens("abcdefghij", "gpt-4o-mini") == {:ok, 3}
  end

  test "chat/2 uses custom base_url, parses token usage, and parses tool calls", %{bypass: bypass} do
    expect_chat_request(bypass, fn conn, body ->
      assert body["model"] == "gpt-4o-mini"
      assert body["messages"] == [%{"role" => "user", "content" => "Hello"}]

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "model" => "gpt-4o-mini",
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "content" => "Hi there",
                "tool_calls" => [
                  %{
                    "id" => "call_123",
                    "type" => "function",
                    "function" => %{
                      "name" => "lookup_weather",
                      "arguments" => Jason.encode!(%{"city" => "Paris"})
                    }
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ],
          "usage" => %{
            "prompt_tokens" => 12,
            "completion_tokens" => 5,
            "total_tokens" => 17
          }
        })
      )
    end)

    assert {:ok,
            %ProviderResponse{
              content: "Hi there",
              model: "gpt-4o-mini",
              finish_reason: "tool_calls",
              token_usage: %TokenUsage{input: 12, output: 5, total: 17},
              tool_calls: [
                %ToolCall{id: "call_123", name: "lookup_weather", arguments: %{"city" => "Paris"}}
              ]
            }} = CopilotBYOK.chat([%{role: "user", content: "Hello"}])
  end

  test "stream/2 produces chunks and final token usage", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/custom/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["model"] == "gpt-4o-mini"
      assert request["stream"] == true
      assert request["stream_options"] == %{"include_usage" => true}
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer copilot-test-secret-key"]

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

    assert {:ok, stream} = CopilotBYOK.stream([%{role: "user", content: "Hello"}])

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

  test "http base_url logs a warning but still succeeds", %{bypass: bypass} do
    expect_chat_request(bypass, fn conn, _body ->
      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "model" => "gpt-4o-mini",
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "Hi"}, "finish_reason" => "stop"}
          ]
        })
      )
    end)

    log =
      capture_log(fn ->
        assert {:ok, %ProviderResponse{content: "Hi"}} =
                 CopilotBYOK.chat([%{role: "user", content: "Hello"}])
      end)

    assert log =~ "HTTP"
    assert log =~ "Copilot BYOK"
  end

  test "api key never appears in logs", %{bypass: bypass, api_key: api_key} do
    expect_chat_request(bypass, fn conn, _body ->
      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "model" => "gpt-4o-mini",
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "Safe"}, "finish_reason" => "stop"}
          ]
        })
      )
    end)

    log =
      capture_log(fn ->
        assert {:ok, %ProviderResponse{content: "Safe"}} =
                 CopilotBYOK.chat([%{role: "user", content: "Hello"}])
      end)

    refute log =~ api_key
  end

  defp expect_chat_request(bypass, fun) do
    Bypass.expect_once(bypass, "POST", "/custom/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer copilot-test-secret-key"]
      assert ["application/json"] = Plug.Conn.get_req_header(conn, "content-type")
      fun.(conn, Jason.decode!(body))
    end)
  end
end
