defmodule Mix.Tasks.OAuthLoginTasksTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ElixirClaw.Providers.Copilot.OAuth
  alias ElixirClaw.Providers.Copilot.TokenManager, as: CopilotTokenManager
  alias ElixirClaw.Providers.OAuthTokenStore

  setup do
    Mix.Task.clear()

    previous_codex = Application.get_env(:elixir_claw, ElixirClaw.Providers.Codex.OAuth)
    previous_copilot = Application.get_env(:elixir_claw, ElixirClaw.Providers.Copilot.OAuth)
    previous_store_config = Application.get_env(:elixir_claw, OAuthTokenStore)
    previous_copilot_client_id = System.get_env("COPILOT_CLIENT_ID")

    storage_path =
      Path.join(System.tmp_dir!(), "oauth-login-task-#{System.unique_integer([:positive])}.json")

    Application.put_env(:elixir_claw, OAuthTokenStore, storage_path: storage_path)

    on_exit(fn ->
      restore_env(ElixirClaw.Providers.Codex.OAuth, previous_codex)
      restore_env(ElixirClaw.Providers.Copilot.OAuth, previous_copilot)

      if previous_store_config do
        Application.put_env(:elixir_claw, OAuthTokenStore, previous_store_config)
      else
        Application.delete_env(:elixir_claw, OAuthTokenStore)
      end

      if is_nil(previous_copilot_client_id) do
        System.delete_env("COPILOT_CLIENT_ID")
      else
        System.put_env("COPILOT_CLIENT_ID", previous_copilot_client_id)
      end

      File.rm(storage_path)
    end)

    %{storage_path: storage_path}
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
                    %{
                      access_token: "codex-token",
                      refresh_token: "codex-refresh",
                      expires_in: 3600
                    }}
  end

  test "mix copilot.login prints device flow instructions and stores the OAuth token" do
    System.delete_env("COPILOT_CLIENT_ID")

    Application.put_env(:elixir_claw, ElixirClaw.Providers.Copilot.OAuth,
      device_code_request: fn opts ->
        assert OAuth.resolve_options(opts)[:client_id] == "Iv1.b507a08c87ecfe98"

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
        assert OAuth.resolve_options(opts)[:client_id] == "Iv1.b507a08c87ecfe98"

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
                    %{
                      access_token: "gho-copilot-token",
                      refresh_token: "ghr-copilot-refresh",
                      expires_in: 28800
                    }}
  end

  test "mix copilot.login prefers COPILOT_CLIENT_ID override when present" do
    System.put_env("COPILOT_CLIENT_ID", "copilot-env-client")

    Application.put_env(:elixir_claw, ElixirClaw.Providers.Copilot.OAuth,
      device_code_request: fn opts ->
        assert OAuth.resolve_options(opts)[:client_id] == "copilot-env-client"

        {:ok,
         %{
           device_code: "device-code-2",
           user_code: "IJKL-MNOP",
           verification_uri: "https://github.com/login/device",
           expires_in: 900,
           interval: 5
         }}
      end,
      device_token_poll: fn device_code, opts ->
        assert device_code == "device-code-2"
        assert OAuth.resolve_options(opts)[:client_id] == "copilot-env-client"

        {:ok,
         %{
           access_token: "gho-copilot-token-2",
           refresh_token: "ghr-copilot-refresh-2",
           expires_in: 28800
         }}
      end,
      token_store: fn token ->
        send(self(), {:copilot_env_token_stored, token})
        :ok
      end
    )

    capture_io(fn ->
      Mix.Tasks.Copilot.Login.run([])
    end)

    assert_receive {:copilot_env_token_stored,
                    %{
                      access_token: "gho-copilot-token-2",
                      refresh_token: "ghr-copilot-refresh-2",
                      expires_in: 28800
                    }}
  end

  test "mix copilot.login stores the token when persisted Copilot state is corrupted", %{
    storage_path: storage_path
  } do
    System.delete_env("COPILOT_CLIENT_ID")
    File.write!(storage_path, "[]")

    Application.put_env(:elixir_claw, ElixirClaw.Providers.Copilot.OAuth,
      device_code_request: fn _opts ->
        {:ok,
         %{
           device_code: "device-code-3",
           user_code: "QRST-UVWX",
           verification_uri: "https://github.com/login/device",
           expires_in: 900,
           interval: 5
         }}
      end,
      device_token_poll: fn "device-code-3", _opts ->
        {:ok,
         %{
           access_token: "ghu-autostart-token",
           refresh_token: nil,
           token_type: "bearer",
           scope: "",
           expires_in: nil,
           refresh_token_expires_in: nil
         }}
      end,
      token_store: &CopilotTokenManager.store_token/1
    )

    output =
      capture_io(fn ->
        Mix.Tasks.Copilot.Login.run([])
      end)

    assert output =~ "GitHub Copilot OAuth token stored."
    assert {:ok, "ghu-autostart-token"} = CopilotTokenManager.get_token()
  end

  test "mix copilot.login updates the persisted token file on repeated runs", %{
    storage_path: storage_path
  } do
    System.delete_env("COPILOT_CLIENT_ID")

    Application.put_env(:elixir_claw, ElixirClaw.Providers.Copilot.OAuth,
      device_code_request: fn _opts ->
        {:ok,
         %{
           device_code: "device-code-repeat-1",
           user_code: "REPT-1111",
           verification_uri: "https://github.com/login/device",
           expires_in: 900,
           interval: 5
         }}
      end,
      device_token_poll: fn "device-code-repeat-1", _opts ->
        {:ok,
         %{
           access_token: "ghu-first-token",
           refresh_token: nil,
           token_type: "bearer",
           scope: "",
           expires_in: nil,
           refresh_token_expires_in: nil
         }}
      end
    )

    capture_io(fn ->
      Mix.Tasks.Copilot.Login.run([])
    end)

    assert File.read!(storage_path) =~ "ghu-first-token"

    if pid = Process.whereis(CopilotTokenManager) do
      GenServer.stop(pid)
    end

    Application.put_env(:elixir_claw, ElixirClaw.Providers.Copilot.OAuth,
      device_code_request: fn _opts ->
        {:ok,
         %{
           device_code: "device-code-repeat-2",
           user_code: "REPT-2222",
           verification_uri: "https://github.com/login/device",
           expires_in: 900,
           interval: 5
         }}
      end,
      device_token_poll: fn "device-code-repeat-2", _opts ->
        {:ok,
         %{
           access_token: "ghu-second-token",
           refresh_token: nil,
           token_type: "bearer",
           scope: "",
           expires_in: nil,
           refresh_token_expires_in: nil
         }}
      end
    )

    capture_io(fn ->
      Mix.Tasks.Copilot.Login.run([])
    end)

    refute File.read!(storage_path) =~ "ghu-first-token"
    assert File.read!(storage_path) =~ "ghu-second-token"
  end

  defp restore_env(module, nil), do: Application.delete_env(:elixir_claw, module)
  defp restore_env(module, config), do: Application.put_env(:elixir_claw, module, config)
end
