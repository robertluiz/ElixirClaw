defmodule ElixirClaw.Providers.Codex.TokenManagerTest do
  use ExUnit.Case, async: false

  alias ElixirClaw.Providers.Codex.{OAuth, TokenManager}

  setup do
    bypass = Bypass.open()
    previous_config = Application.get_env(:elixir_claw, OAuth)

    Application.put_env(:elixir_claw, OAuth,
      client_id: "codex-client",
      token_url: "http://localhost:#{bypass.port}/oauth/token"
    )

    start_supervised!(TokenManager)

    on_exit(fn ->
      if previous_config do
        Application.put_env(:elixir_claw, OAuth, previous_config)
      else
        Application.delete_env(:elixir_claw, OAuth)
      end
    end)

    %{bypass: bypass}
  end

  test "store_token/1 then get_token/0 returns the access token" do
    assert :ok =
             TokenManager.store_token(%{
               access_token: "access-token",
               refresh_token: "refresh-token",
               expires_in: 3600
             })

    assert {:ok, "access-token"} = TokenManager.get_token()
  end

  test "token_valid?/0 is false before store and true after store" do
    refute TokenManager.token_valid?()

    assert :ok =
             TokenManager.store_token(%{
               access_token: "access-token",
               refresh_token: "refresh-token",
               expires_in: 3600
             })

    assert TokenManager.token_valid?()
  end

  test "clear_token/0 removes tokens and get_token/0 returns no_token" do
    assert :ok =
             TokenManager.store_token(%{
               access_token: "access-token",
               refresh_token: "refresh-token",
               expires_in: 3600
             })

    assert :ok = TokenManager.clear_token()
    assert {:error, :no_token} = TokenManager.get_token()
    refute TokenManager.token_valid?()
  end

  test "get_token/0 auto-refreshes tokens that are close to expiry", %{bypass: bypass} do
    assert :ok =
             TokenManager.store_token(%{
               access_token: "stale-token",
               refresh_token: "refresh-token",
               expires_in: 60
             })

    Bypass.expect_once(bypass, "POST", "/oauth/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      assert params["grant_type"] == "refresh_token"
      assert params["refresh_token"] == "refresh-token"
      assert params["client_id"] == "codex-client"

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "access_token" => "fresh-token",
          "refresh_token" => "fresh-refresh-token",
          "expires_in" => 3600,
          "token_type" => "Bearer"
        })
      )
    end)

    assert {:ok, "fresh-token"} = TokenManager.get_token()
    assert TokenManager.token_valid?()
    assert {:ok, "fresh-token"} = TokenManager.get_token()
  end
end
