defmodule ElixirClaw.Providers.Copilot.ClientTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ElixirClaw.Providers.Copilot.{Client, TokenManager}
  alias ElixirClaw.Providers.OAuthTokenStore
  alias ElixirClaw.Types.ProviderResponse

  setup do
    previous_config = Application.get_env(:elixir_claw, Client)
    previous_store_config = Application.get_env(:elixir_claw, OAuthTokenStore)

    storage_path =
      Path.join(
        System.tmp_dir!(),
        "copilot-client-test-#{System.unique_integer([:positive])}.json"
      )

    Application.put_env(:elixir_claw, OAuthTokenStore, storage_path: storage_path)

    Application.put_env(:elixir_claw, Client,
      use_node_bridge: true,
      models: ["gpt-4o-mini"],
      command_runner: fn _request ->
        {:ok,
         Jason.encode!(%{
           "ok" => true,
           "content" => "Hi from bridge",
           "model" => "gpt-4o-mini",
           "finish_reason" => "stop",
           "tool_calls" => [],
           "token_usage" => nil
         })}
      end
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
      File.rm(storage_path)

      if previous_config do
        Application.put_env(:elixir_claw, Client, previous_config)
      else
        Application.delete_env(:elixir_claw, Client)
      end

      if previous_store_config do
        Application.put_env(:elixir_claw, OAuthTokenStore, previous_store_config)
      else
        Application.delete_env(:elixir_claw, OAuthTokenStore)
      end
    end)

    :ok
  end

  test "name/0 returns github_copilot" do
    assert Client.name() == "github_copilot"
  end

  test "chat/2 delegates to the node bridge and parses the provider response" do
    assert {:ok, %ProviderResponse{content: "Hi from bridge", model: "gpt-4o-mini", finish_reason: "stop"}} =
             Client.chat([%{role: "user", content: "Hello"}])
  end

  test "missing token returns no_token before bridge invocation" do
    assert :ok = TokenManager.clear_token()
    assert Client.chat([%{role: "user", content: "Hello"}]) == {:error, :no_token}
  end

  test "chat/2 falls back to the next configured model on request_failed" do
    parent = self()

    Application.put_env(:elixir_claw, Client,
      use_node_bridge: true,
      models: ["gpt-5.4-mini", "gpt-4o-mini"],
      command_runner: fn request ->
        payload = Jason.decode!(request.input)
        send(parent, {:copilot_model_attempt, payload["model"]})

        case payload["model"] do
          "gpt-5.4-mini" -> {:ok, Jason.encode!(%{"ok" => false, "error" => "request_failed"})}
          "gpt-4o-mini" -> {:ok, Jason.encode!(%{"ok" => true, "content" => "fallback worked", "model" => "gpt-4o-mini", "finish_reason" => "stop", "tool_calls" => [], "token_usage" => nil})}
        end
      end
    )

    assert {:ok, %ProviderResponse{content: "fallback worked", model: "gpt-4o-mini"}} =
             Client.chat([%{role: "user", content: "Hello"}])

    assert_receive {:copilot_model_attempt, "gpt-5.4-mini"}
    assert_receive {:copilot_model_attempt, "gpt-4o-mini"}
  end

  test "chat/2 forwards the stored github token to the bridge" do
    parent = self()

    Application.put_env(:elixir_claw, Client,
      use_node_bridge: true,
      models: ["gpt-4o-mini"],
      command_runner: fn request ->
        payload = Jason.decode!(request.input)
        send(parent, {:bridge_token, payload["githubToken"]})
        {:ok, Jason.encode!(%{"ok" => true, "content" => "ok", "model" => "gpt-4o-mini", "finish_reason" => "stop", "tool_calls" => [], "token_usage" => nil})}
      end
    )

    assert {:ok, %ProviderResponse{content: "ok"}} = Client.chat([%{role: "user", content: "Hello"}])
    assert_receive {:bridge_token, "gho-copilot-token"}
  end

  test "bridge errors are normalized" do
    Application.put_env(:elixir_claw, Client,
      use_node_bridge: true,
      models: ["gpt-4o-mini"],
      command_runner: fn _request -> {:ok, Jason.encode!(%{"ok" => false, "error" => "unauthorized"})} end
    )

    assert Client.chat([%{role: "user", content: "Hello"}]) == {:error, :unauthorized}
  end

  test "fallback logs remain visible when bridge rejects the current model" do
    Application.put_env(:elixir_claw, Client,
      use_node_bridge: true,
      models: ["gpt-5.4-mini", "gpt-4o-mini"],
      command_runner: fn request ->
        payload = Jason.decode!(request.input)

        case payload["model"] do
          "gpt-5.4-mini" -> {:ok, Jason.encode!(%{"ok" => false, "error" => "request_failed"})}
          _ -> {:ok, Jason.encode!(%{"ok" => true, "content" => "ok", "model" => "gpt-4o-mini", "finish_reason" => "stop", "tool_calls" => [], "token_usage" => nil})}
        end
      end
    )

    log =
      capture_log(fn ->
        assert {:ok, %ProviderResponse{content: "ok"}} = Client.chat([%{role: "user", content: "Hello"}])
      end)

    assert log =~ "Copilot request failed for model gpt-5.4-mini; retrying with fallback model gpt-4o-mini"
  end
end
