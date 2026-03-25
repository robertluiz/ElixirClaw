defmodule ElixirClaw.Providers.Copilot.ClientTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ElixirClaw.Providers.Copilot.{Client, TokenManager}
  alias ElixirClaw.Types.{ProviderResponse, TokenUsage, ToolCall}

  setup do
    bypass = Bypass.open()
    previous_config = Application.get_env(:elixir_claw, Client)

    Application.put_env(:elixir_claw, Client,
      base_url: "http://localhost:#{bypass.port}",
      models: ["gpt-4o-mini"]
    )

    assert :ok = TokenManager.clear_token()

    assert :ok =
             TokenManager.store_token(%{
               access_token: "gho-copilot-token",
               refresh_token: "ghr-copilot-refresh",
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

    %{bypass: bypass, access_token: "gho-copilot-token"}
  end

  test "name/0 returns github_copilot" do
    assert Client.name() == "github_copilot"
  end

  test "chat/2 uses OAuth bearer token and parses tool calls", %{bypass: bypass} do
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
                "content" => "Hi from Copilot",
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
              content: "Hi from Copilot",
              model: "gpt-4o-mini",
              finish_reason: "tool_calls",
              token_usage: %TokenUsage{input: 12, output: 5, total: 17},
              tool_calls: [
                %ToolCall{id: "call_123", name: "lookup_weather", arguments: %{"city" => "Paris"}}
              ]
            }} = Client.chat([%{role: "user", content: "Hello"}])
  end

  test "missing token returns no_token without making a request" do
    assert :ok = TokenManager.clear_token()
    assert Client.chat([%{role: "user", content: "Hello"}]) == {:error, :no_token}
  end

  test "unauthorized responses are sanitized and never log secrets", %{
    bypass: bypass,
    access_token: access_token
  } do
    expect_chat_request(bypass, fn conn, _body ->
      Plug.Conn.resp(
        conn,
        401,
        Jason.encode!(%{
          "error" => %{
            "message" => "token #{access_token} is invalid"
          }
        })
      )
    end)

      log =
        capture_log(fn ->
          assert Client.chat([%{role: "user", content: "Hello"}]) == {:error, :unauthorized}
        end)

      refute log =~ access_token
  end

  defp expect_chat_request(bypass, fun) do
    Bypass.expect_once(bypass, "POST", "/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer gho-copilot-token"]
      assert ["application/json"] = Plug.Conn.get_req_header(conn, "content-type")
      fun.(conn, Jason.decode!(body))
    end)
  end
end
