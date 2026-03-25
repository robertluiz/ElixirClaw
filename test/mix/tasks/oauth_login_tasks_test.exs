defmodule Mix.Tasks.OAuthLoginTasksTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    Mix.Task.clear()

    previous_codex = Application.get_env(:elixir_claw, ElixirClaw.Providers.Codex.OAuth)
    previous_copilot = Application.get_env(:elixir_claw, ElixirClaw.Providers.Copilot.OAuth)

    on_exit(fn ->
      restore_env(ElixirClaw.Providers.Codex.OAuth, previous_codex)
      restore_env(ElixirClaw.Providers.Copilot.OAuth, previous_copilot)
    end)

    :ok
  end

  test "mix codex.login prints the authorization url and stores the exchanged token" do
    Application.put_env(:elixir_claw, ElixirClaw.Providers.Codex.OAuth,
      client_id: "codex-client",
      redirect_uri: "http://localhost:1455/callback",
      auth_code_exchange: fn code, verifier, opts ->
        assert code == "auth-code-123"
        assert is_binary(verifier)
        assert opts[:client_id] == "codex-client"

        {:ok, %{access_token: "codex-token", refresh_token: "codex-refresh", expires_in: 3600}}
      end,
      token_store: fn token ->
        send(self(), {:codex_token_stored, token})
        :ok
      end
    )

    output =
      capture_io("auth-code-123\n", fn ->
        Mix.Tasks.Codex.Login.run([])
      end)

    assert output =~ "auth0.openai.com/authorize"
    assert output =~ "Paste the authorization code"

    assert_receive {:codex_token_stored,
                    %{access_token: "codex-token", refresh_token: "codex-refresh", expires_in: 3600}}
  end

  test "mix copilot.login prints device flow instructions and stores the OAuth token" do
    Application.put_env(:elixir_claw, ElixirClaw.Providers.Copilot.OAuth,
      client_id: "copilot-client",
      device_code_request: fn opts ->
        assert opts[:client_id] == "copilot-client"

        {:ok,
         %{
           device_code: "device-code-1",
           user_code: "ABCD-EFGH",
           verification_uri: "https://github.com/login/device",
           expires_in: 900,
           interval: 5
         }}
      end,
      device_token_poll: fn device_code, opts ->
        assert device_code == "device-code-1"
        assert opts[:client_id] == "copilot-client"

        {:ok,
         %{
           access_token: "gho-copilot-token",
           refresh_token: "ghr-copilot-refresh",
           expires_in: 28800
         }}
      end,
      token_store: fn token ->
        send(self(), {:copilot_token_stored, token})
        :ok
      end
    )

    output =
      capture_io(fn ->
        Mix.Tasks.Copilot.Login.run([])
      end)

    assert output =~ "https://github.com/login/device"
    assert output =~ "ABCD-EFGH"
    assert output =~ "Waiting for authorization"

    assert_receive {:copilot_token_stored,
                     %{access_token: "gho-copilot-token", refresh_token: "ghr-copilot-refresh", expires_in: 28800}}
  end

  defp restore_env(module, nil), do: Application.delete_env(:elixir_claw, module)
  defp restore_env(module, config), do: Application.put_env(:elixir_claw, module, config)
end
