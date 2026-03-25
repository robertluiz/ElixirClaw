defmodule ElixirClaw.Providers.Copilot.OAuthTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ElixirClaw.Providers.Copilot.OAuth

  setup do
    bypass = Bypass.open()
    previous_config = Application.get_env(:elixir_claw, OAuth)
    previous_client_id = System.get_env("COPILOT_CLIENT_ID")

    Application.put_env(:elixir_claw, OAuth,
      client_id: "copilot-client",
      device_code_url: "http://localhost:#{bypass.port}/login/device/code",
      token_url: "http://localhost:#{bypass.port}/login/oauth/access_token"
    )

    on_exit(fn ->
      if previous_config do
        Application.put_env(:elixir_claw, OAuth, previous_config)
      else
        Application.delete_env(:elixir_claw, OAuth)
      end

      if is_nil(previous_client_id) do
        System.delete_env("COPILOT_CLIENT_ID")
      else
        System.put_env("COPILOT_CLIENT_ID", previous_client_id)
      end
    end)

    %{bypass: bypass, client_id: "copilot-client"}
  end

  test "device_code/1 requests a GitHub device code with read:user scope", %{
    bypass: bypass,
    client_id: client_id
  } do
    Bypass.expect_once(bypass, "POST", "/login/device/code", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      assert params["client_id"] == client_id
      assert params["scope"] == "read:user"

      assert ["application/x-www-form-urlencoded"] =
               Plug.Conn.get_req_header(conn, "content-type")

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "device_code" => "device-code-1",
          "user_code" => "ABCD-EFGH",
          "verification_uri" => "https://github.com/login/device",
          "expires_in" => 900,
          "interval" => 5
        })
      )
    end)

    assert {:ok,
            %{
              device_code: "device-code-1",
              user_code: "ABCD-EFGH",
              verification_uri: "https://github.com/login/device",
              expires_in: 900,
              interval: 5
            }} = OAuth.device_code(client_id: client_id)
  end

  test "poll_device_token/2 exchanges the device code for an OAuth token", %{
    bypass: bypass,
    client_id: client_id
  } do
    Bypass.expect_once(bypass, "POST", "/login/oauth/access_token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      assert params["client_id"] == client_id
      assert params["device_code"] == "device-code-1"
      assert params["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code"

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "access_token" => "gho_test_token",
          "refresh_token" => "ghr_refresh_token",
          "token_type" => "bearer",
          "scope" => "read:user",
          "expires_in" => 28800,
          "refresh_token_expires_in" => 15_897_600
        })
      )
    end)

    assert {:ok,
            %{
              access_token: "gho_test_token",
              refresh_token: "ghr_refresh_token",
              token_type: "bearer",
              scope: "read:user",
              expires_in: 28800,
              refresh_token_expires_in: 15_897_600
            }} = OAuth.poll_device_token("device-code-1", client_id: client_id)
  end

  test "poll_device_token/2 keeps polling until authorization completes", %{client_id: client_id} do
    requester = fn _request_opts ->
      case Process.get(:copilot_poll_count, 0) do
        0 ->
          Process.put(:copilot_poll_count, 1)
          {:ok, %Req.Response{status: 200, body: %{"error" => "authorization_pending"}}}

        _count ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "access_token" => "gho_test_token",
               "refresh_token" => "ghr_refresh_token",
               "token_type" => "bearer",
               "scope" => "read:user",
               "expires_in" => 28800,
               "refresh_token_expires_in" => 15_897_600
             }
           }}
      end
    end

    sleeper = fn duration_ms -> send(self(), {:poll_sleep, duration_ms}) end

    assert {:ok, %{access_token: "gho_test_token"}} =
             OAuth.poll_device_token("device-code-1",
               client_id: client_id,
               requester: requester,
               sleep: sleeper,
               interval: 1,
               poll_timeout_ms: 5_000
             )

    assert_receive {:poll_sleep, 1_000}
  end

  test "refresh_token/2 exchanges refresh tokens for new access tokens", %{
    bypass: bypass,
    client_id: client_id
  } do
    Bypass.expect_once(bypass, "POST", "/login/oauth/access_token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      assert params["grant_type"] == "refresh_token"
      assert params["refresh_token"] == "ghr_refresh_token"
      assert params["client_id"] == client_id

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "access_token" => "gho_fresh_token",
          "refresh_token" => "ghr_fresh_refresh",
          "token_type" => "bearer",
          "expires_in" => 28800
        })
      )
    end)

    assert {:ok,
            %{
              access_token: "gho_fresh_token",
              refresh_token: "ghr_fresh_refresh",
              token_type: "bearer",
              expires_in: 28800
            }} =
             OAuth.refresh_token("ghr_refresh_token",
               client_id: client_id,
               token_url: "http://localhost:#{bypass.port}/login/oauth/access_token"
             )
  end

  test "token secrets never appear in logs", %{client_id: client_id} do
    access_token = "gho-secret-token"
    refresh_token = "ghr-secret-refresh"

    log =
      capture_log(fn ->
        assert OAuth.poll_device_token("bad-device-code",
                 client_id: client_id,
                 requester: fn _request_opts ->
                   {:ok,
                    %Req.Response{
                      status: 401,
                      body: %{
                        "error_description" =>
                          "failed #{access_token} #{refresh_token} for device flow"
                      }
                    }}
                 end
               ) == {:error, :unauthorized}
      end)

    refute log =~ access_token
    refute log =~ refresh_token
  end

  test "device_code/1 falls back to the default Copilot client id when app config is missing", %{
    bypass: bypass
  } do
    Application.delete_env(:elixir_claw, OAuth)
    System.delete_env("COPILOT_CLIENT_ID")

    Bypass.expect_once(bypass, "POST", "/login/device/code", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      assert params["client_id"] == "Iv1.b507a08c87ecfe98"

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "device_code" => "device-code-env",
          "user_code" => "WXYZ-1234",
          "verification_uri" => "https://github.com/login/device",
          "expires_in" => 900,
          "interval" => 5
        })
      )
    end)

    assert {:ok,
            %{
              device_code: "device-code-env",
              user_code: "WXYZ-1234",
              verification_uri: "https://github.com/login/device",
              expires_in: 900,
              interval: 5
            }} =
             OAuth.device_code(
               device_code_url: "http://localhost:#{bypass.port}/login/device/code"
             )
  end

  test "device_code/1 prefers COPILOT_CLIENT_ID override over the default", %{bypass: bypass} do
    Application.delete_env(:elixir_claw, OAuth)
    System.put_env("COPILOT_CLIENT_ID", "copilot-env-client")

    Bypass.expect_once(bypass, "POST", "/login/device/code", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      assert params["client_id"] == "copilot-env-client"

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "device_code" => "device-code-env-override",
          "user_code" => "QRST-5678",
          "verification_uri" => "https://github.com/login/device",
          "expires_in" => 900,
          "interval" => 5
        })
      )
    end)

    assert {:ok,
            %{
              device_code: "device-code-env-override",
              user_code: "QRST-5678",
              verification_uri: "https://github.com/login/device",
              expires_in: 900,
              interval: 5
            }} =
             OAuth.device_code(
               device_code_url: "http://localhost:#{bypass.port}/login/device/code"
             )
  end
end
