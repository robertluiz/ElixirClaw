defmodule ElixirClaw.Providers.OpenRouterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ElixirClaw.Providers.OpenRouter
  alias ElixirClaw.Types.{ProviderResponse, TokenUsage}

  setup do
    bypass = Bypass.open()
    previous_config = Application.get_env(:elixir_claw, OpenRouter)

    Application.put_env(:elixir_claw, OpenRouter,
      api_key: "or-test-secret-key",
      base_url: "http://localhost:#{bypass.port}/api/v1",
      referer_url: "https://github.com/example/elixirclaw",
      app_title: "ElixirClaw",
      models: ["openai/gpt-4o", "anthropic/claude-3-5-sonnet"],
      transforms: ["middle-out"]
    )

    on_exit(fn ->
      if previous_config do
        Application.put_env(:elixir_claw, OpenRouter, previous_config)
      else
        Application.delete_env(:elixir_claw, OpenRouter)
      end
    end)

    %{bypass: bypass, api_key: "or-test-secret-key"}
  end

  test "name/0 returns openrouter" do
    assert OpenRouter.name() == "openrouter"
  end

  test "models/0 returns configured provider/model identifiers" do
    assert OpenRouter.models() == ["openai/gpt-4o", "anthropic/claude-3-5-sonnet"]
  end

  test "count_tokens/2 uses char heuristic" do
    assert OpenRouter.count_tokens("abcdefghij", "openai/gpt-4o") == {:ok, 3}
  end

  test "chat/2 sends OpenRouter headers, model, transforms, and parses token usage", %{
    bypass: bypass
  } do
    expect_chat_request(bypass, fn conn, body ->
      assert body["model"] == "anthropic/claude-3-5-sonnet"
      assert body["messages"] == [%{"role" => "user", "content" => "Hello"}]
      assert body["transforms"] == ["middle-out"]

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "model" => "anthropic/claude-3-5-sonnet",
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => "Hi there"},
              "finish_reason" => "stop"
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
              model: "anthropic/claude-3-5-sonnet",
              finish_reason: "stop",
              tool_calls: [],
              token_usage: %TokenUsage{input: 12, output: 5, total: 17}
            }} =
             OpenRouter.chat([%{role: "user", content: "Hello"}],
               model: "anthropic/claude-3-5-sonnet"
             )
  end

  test "stream/2 returns chunks and includes usage on final event", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["model"] == "openai/gpt-4o"
      assert request["stream"] == true
      assert request["stream_options"] == %{"include_usage" => true}
      assert request["transforms"] == ["middle-out"]
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer or-test-secret-key"]
      assert Plug.Conn.get_req_header(conn, "http-referer") == ["https://github.com/example/elixirclaw"]
      assert Plug.Conn.get_req_header(conn, "x-title") == ["ElixirClaw"]

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

    assert {:ok, stream} = OpenRouter.stream([%{role: "user", content: "Hello"}])

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

  test "chat/2 maps 429 to :rate_limited", %{bypass: bypass} do
    expect_chat_request(bypass, fn conn, _body ->
      Plug.Conn.resp(
        conn,
        429,
        Jason.encode!(%{"error" => %{"message" => "rate limit exceeded", "type" => "rate_limit"}})
      )
    end)

    assert OpenRouter.chat([%{role: "user", content: "Hello"}]) == {:error, :rate_limited}
  end

  test "unauthorized responses never log the API key", %{bypass: bypass, api_key: api_key} do
    expect_chat_request(bypass, fn conn, _body ->
      Plug.Conn.resp(
        conn,
        401,
        Jason.encode!(%{
          "error" => %{
            "message" => "Invalid API key #{api_key}",
            "type" => "invalid_request_error"
          }
        })
      )
    end)

    log =
      capture_log(fn ->
        assert OpenRouter.chat([%{role: "user", content: "Hello"}]) == {:error, :unauthorized}
      end)

    refute log =~ api_key
  end

  defp expect_chat_request(bypass, fun) do
    Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer or-test-secret-key"]
      assert ["application/json"] = Plug.Conn.get_req_header(conn, "content-type")
      assert Plug.Conn.get_req_header(conn, "http-referer") == ["https://github.com/example/elixirclaw"]
      assert Plug.Conn.get_req_header(conn, "x-title") == ["ElixirClaw"]
      fun.(conn, Jason.decode!(body))
    end)
  end
end
