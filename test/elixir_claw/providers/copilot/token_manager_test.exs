defmodule ElixirClaw.Providers.Copilot.TokenManagerTest do
  use ExUnit.Case, async: false

  alias ElixirClaw.Providers.Copilot.{OAuth, TokenManager}
  alias ElixirClaw.Providers.OAuthTokenStore

  setup do
    previous_oauth_config = Application.get_env(:elixir_claw, OAuth)
    previous_store_config = Application.get_env(:elixir_claw, OAuthTokenStore)

    storage_path =
      Path.join(
        System.tmp_dir!(),
        "copilot-token-manager-#{System.unique_integer([:positive])}.json"
      )

    Application.put_env(:elixir_claw, OAuth, client_id: "copilot-client")
    Application.put_env(:elixir_claw, OAuthTokenStore, storage_path: storage_path)

    assert :ok = TokenManager.clear_token()

    on_exit(fn ->
      assert :ok = TokenManager.clear_token()

      File.rm(storage_path)

      if previous_oauth_config do
        Application.put_env(:elixir_claw, OAuth, previous_oauth_config)
      else
        Application.delete_env(:elixir_claw, OAuth)
      end

      if previous_store_config do
        Application.put_env(:elixir_claw, OAuthTokenStore, previous_store_config)
      else
        Application.delete_env(:elixir_claw, OAuthTokenStore)
      end
    end)

    %{storage_path: storage_path}
  end

  test "store_token/1 then get_token/0 returns the access token" do
    assert :ok =
             TokenManager.store_token(%{
               access_token: "gho-access-token",
               refresh_token: "ghr-refresh-token",
               expires_in: 3600
             })

    assert {:ok, "gho-access-token"} = TokenManager.get_token()
  end

  test "clear_token/0 removes tokens and get_token/0 returns no_token" do
    assert :ok =
             TokenManager.store_token(%{
               access_token: "gho-access-token",
               refresh_token: "ghr-refresh-token",
               expires_in: 3600
             })

    assert :ok = TokenManager.clear_token()
    assert {:error, :no_token} = TokenManager.get_token()
    refute TokenManager.token_valid?()
  end

  test "clear_token/0 deletes the persisted token file", %{storage_path: storage_path} do
    assert :ok =
             TokenManager.store_token(%{
               access_token: "gho-access-token",
               refresh_token: "ghr-refresh-token",
               expires_in: 3600
             })

    assert File.exists?(storage_path)

    assert :ok = TokenManager.clear_token()
    refute File.exists?(storage_path)
  end

  test "persist_token_response/1 preserves existing tokens when response omits auth fields", %{
    storage_path: storage_path
  } do
    assert :ok =
             TokenManager.store_token(%{
               access_token: "gho-access-token",
               refresh_token: "ghr-refresh-token",
               expires_in: 3600
             })

    assert :ok = TokenManager.persist_token_response(%{"token_type" => "bearer"})
    assert {:ok, "gho-access-token"} = TokenManager.get_token()

    persisted = OAuthTokenStore.load("copilot", storage_path: storage_path)

    assert persisted.access_token == "gho-access-token"
    assert persisted.refresh_token == "ghr-refresh-token"
  end

  test "persist_token_response/1 without auth fields does not create a null token file", %{
    storage_path: storage_path
  } do
    assert :ok = TokenManager.clear_token()
    refute File.exists?(storage_path)

    assert :ok = TokenManager.persist_token_response(%{"token_type" => "bearer"})

    refute File.exists?(storage_path)
    assert {:error, :no_token} = TokenManager.get_token()
  end

  test "get_token/0 refreshes tokens close to expiry" do
    Application.put_env(:elixir_claw, OAuth,
      client_id: "copilot-client",
      refresh_token: fn refresh_token, _opts ->
        assert refresh_token == "ghr-refresh-token"

        {:ok,
         %{
           access_token: "gho-fresh-token",
           refresh_token: "ghr-fresh-refresh-token",
           expires_in: 3600
         }}
      end
    )

    assert :ok =
             TokenManager.store_token(%{
               access_token: "gho-access-token",
               refresh_token: "ghr-refresh-token",
               expires_in: 60
             })

    assert {:ok, "gho-fresh-token"} = TokenManager.get_token()
    assert TokenManager.token_valid?()
  end

  test "loads persisted tokens after the process restarts", %{storage_path: storage_path} do
    manager_name = isolated_manager_name("copilot")

    assert {:ok, pid} = TokenManager.start_link(name: manager_name)

    assert :ok =
             GenServer.call(manager_name, {
               :store_token,
               %{
                 access_token: "gho-persisted-token",
                 refresh_token: "ghr-persisted-refresh",
                 expires_in: 3600
               }
             })

    GenServer.stop(pid)
    assert {:ok, _pid} = TokenManager.start_link(name: manager_name)

    assert {:ok, "gho-persisted-token"} = GenServer.call(manager_name, :get_token)
    assert File.exists?(storage_path)
  end

  test "loads with corrupted persisted token structure without crashing", %{
    storage_path: storage_path
  } do
    File.write!(storage_path, "[]")

    manager_name = isolated_manager_name("copilot-corrupted")
    assert {:ok, _pid} = TokenManager.start_link(name: manager_name)

    assert {:error, :no_token} = GenServer.call(manager_name, :get_token)
    refute GenServer.call(manager_name, :token_valid?)
  end

  defp isolated_manager_name(prefix) do
    {:global, {__MODULE__, prefix, System.unique_integer([:positive])}}
  end
end
