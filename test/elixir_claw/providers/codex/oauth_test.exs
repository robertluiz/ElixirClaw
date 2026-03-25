defmodule ElixirClaw.Providers.Codex.OAuthTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ElixirClaw.Providers.Codex.OAuth

  setup do
    bypass = Bypass.open()
    previous_config = Application.get_env(:elixir_claw, OAuth)

    Application.put_env(:elixir_claw, OAuth,
      client_id: "codex-client",
      redirect_uri: "http://localhost:1455/callback",
      token_url: "http://localhost:#{bypass.port}/oauth/token"
    )

    on_exit(fn ->
      if previous_config do
        Application.put_env(:elixir_claw, OAuth, previous_config)
      else
        Application.delete_env(:elixir_claw, OAuth)
      end
    end)

    %{bypass: bypass, client_id: "codex-client", redirect_uri: "http://localhost:1455/callback"}
  end

  test "generate_pkce/0 returns URL-safe verifier in RFC 7636 length bounds" do
    pkce = OAuth.generate_pkce()

    assert pkce.method == "S256"
    assert String.length(pkce.verifier) in 43..128
    assert pkce.verifier =~ ~r/\A[A-Za-z0-9_-]+\z/
  end

  test "generate_pkce/0 derives challenge from verifier" do
    pkce = OAuth.generate_pkce()

    expected_challenge =
      pkce.verifier
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    assert pkce.challenge == expected_challenge
  end

  test "auth_url/1 includes required OAuth params", %{
    client_id: client_id,
    redirect_uri: redirect_uri
  } do
    url =
      OAuth.auth_url(
        client_id: client_id,
        redirect_uri: redirect_uri,
        code_challenge: "challenge-123",
        state: "csrf-state"
      )

    assert %URI{scheme: "https", host: "auth0.openai.com", path: "/authorize", query: query} =
             URI.parse(url)

    params = URI.decode_query(query)

    assert params["client_id"] == client_id
    assert params["redirect_uri"] == redirect_uri
    assert params["response_type"] == "code"
    assert params["audience"] == "https://api.openai.com/v1"
    assert params["scope"] == "openid profile email offline_access"
    assert params["code_challenge"] == "challenge-123"
    assert params["code_challenge_method"] == "S256"
    assert params["state"] == "csrf-state"
  end

  test "exchange_code/3 uses an HTTPS token endpoint by default", %{
    client_id: client_id,
    redirect_uri: redirect_uri
  } do
    requester = fn request_opts ->
      assert String.starts_with?(request_opts[:url], "https://")

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "access_token" => "https-token",
           "refresh_token" => "https-refresh",
           "expires_in" => 3600,
           "token_type" => "Bearer"
         }
       }}
    end

    assert {:ok, %{access_token: "https-token", refresh_token: "https-refresh"}} =
             OAuth.exchange_code("auth-code", "verifier-secret",
               client_id: client_id,
               redirect_uri: redirect_uri,
               token_url: nil,
               requester: requester
             )
  end

  test "exchange_code/3 sends POST to the token endpoint", %{
    bypass: bypass,
    client_id: client_id,
    redirect_uri: redirect_uri
  } do
    Bypass.expect_once(bypass, "POST", "/oauth/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      assert ["application/x-www-form-urlencoded"] =
               Plug.Conn.get_req_header(conn, "content-type")

      assert params["grant_type"] == "authorization_code"
      assert params["code"] == "auth-code"
      assert params["code_verifier"] == "verifier-secret"
      assert params["redirect_uri"] == redirect_uri
      assert params["client_id"] == client_id

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "access_token" => "test_token",
          "refresh_token" => "test_refresh",
          "expires_in" => 3600,
          "token_type" => "Bearer"
        })
      )
    end)

    assert {:ok,
            %{
              access_token: "test_token",
              refresh_token: "test_refresh",
              expires_in: 3600,
              token_type: "Bearer"
            }} =
             OAuth.exchange_code("auth-code", "verifier-secret",
               client_id: client_id,
               redirect_uri: redirect_uri,
               token_url: "http://localhost:#{bypass.port}/oauth/token"
             )
  end

  test "refresh_token/2 sends the refresh_token grant type", %{
    bypass: bypass,
    client_id: client_id
  } do
    Bypass.expect_once(bypass, "POST", "/oauth/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      assert params["grant_type"] == "refresh_token"
      assert params["refresh_token"] == "test_refresh"
      assert params["client_id"] == client_id

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "access_token" => "new_access_token",
          "refresh_token" => "new_refresh_token",
          "expires_in" => 3600,
          "token_type" => "Bearer"
        })
      )
    end)

    assert {:ok,
            %{
              access_token: "new_access_token",
              refresh_token: "new_refresh_token",
              expires_in: 3600,
              token_type: "Bearer"
            }} =
             OAuth.refresh_token(test_refresh = "test_refresh",
               client_id: client_id,
               token_url: "http://localhost:#{bypass.port}/oauth/token"
             )

    assert test_refresh == "test_refresh"
  end

  test "token secrets never appear in logs", %{client_id: client_id, redirect_uri: redirect_uri} do
    access_token = "secret-access-token"
    refresh_token = "secret-refresh-token"
    code_verifier = "secret-code-verifier"

    log =
      capture_log(fn ->
        assert OAuth.exchange_code("bad-code", code_verifier,
                 client_id: client_id,
                 redirect_uri: redirect_uri,
                 requester: fn _request_opts ->
                   {:ok,
                    %Req.Response{
                      status: 401,
                      body: %{
                        "error" => %{
                          "message" => "failed #{access_token} #{refresh_token} #{code_verifier}"
                        }
                      }
                    }}
                 end
               ) == {:error, :unauthorized}
      end)

    refute log =~ access_token
    refute log =~ refresh_token
    refute log =~ code_verifier
  end
end
