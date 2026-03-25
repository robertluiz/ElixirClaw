defmodule ElixirClaw.Providers.Codex.OAuth do
  @moduledoc """
  OAuth helpers for the Codex PKCE authorization flow.
  """

  @default_authorize_url "https://auth0.openai.com/authorize"
  @default_token_url "https://auth0.openai.com/oauth/token"
  @default_audience "https://api.openai.com/v1"
  @default_scope "openid profile email offline_access"
  @pkce_verifier_bytes 48

  @type token_response :: %{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          expires_in: pos_integer(),
          token_type: String.t() | nil
        }

  @spec generate_pkce() :: %{verifier: String.t(), challenge: String.t(), method: String.t()}
  def generate_pkce do
    verifier =
      @pkce_verifier_bytes
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    %{
      verifier: verifier,
      challenge: generate_code_challenge(verifier),
      method: "S256"
    }
  end

  @spec auth_url(keyword()) :: String.t()
  def auth_url(opts) when is_list(opts) do
    opts = merged_options(opts)

    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => Keyword.fetch!(opts, :client_id),
        "redirect_uri" => Keyword.fetch!(opts, :redirect_uri),
        "audience" => @default_audience,
        "scope" => @default_scope,
        "code_challenge" => Keyword.fetch!(opts, :code_challenge),
        "code_challenge_method" => "S256",
        "state" => Keyword.get(opts, :state, generate_state())
      })

    @default_authorize_url <> "?" <> query
  end

  @spec exchange_code(String.t(), String.t(), keyword()) ::
          {:ok, token_response()} | {:error, term()}
  def exchange_code(code, code_verifier, opts)
      when is_binary(code) and is_binary(code_verifier) and is_list(opts) do
    opts = merged_options(opts)

    request_oauth_token(
      [
        {"grant_type", "authorization_code"},
        {"code", code},
        {"code_verifier", code_verifier},
        {"redirect_uri", Keyword.fetch!(opts, :redirect_uri)},
        {"client_id", Keyword.fetch!(opts, :client_id)}
      ],
      opts
    )
  end

  @spec refresh_token(String.t(), keyword()) :: {:ok, token_response()} | {:error, term()}
  def refresh_token(refresh_token, opts) when is_binary(refresh_token) and is_list(opts) do
    opts = merged_options(opts)

    request_oauth_token(
      [
        {"grant_type", "refresh_token"},
        {"refresh_token", refresh_token},
        {"client_id", Keyword.fetch!(opts, :client_id)}
      ],
      opts
    )
  end

  defp request_oauth_token(form_params, opts) do
    with {:ok, token_url} <- token_url(opts),
         {:ok, response} <- requester(opts).(token_request_options(token_url, form_params)),
         :ok <- validate_response(response),
         {:ok, body} <- decode_body(response.body),
         {:ok, normalized} <- normalize_token_response(body) do
      {:ok, normalized}
    else
      {:error, _reason} = error -> error
    end
  end

  defp token_request_options(token_url, form_params) do
    [
      url: token_url,
      headers: [
        {"content-type", "application/x-www-form-urlencoded"},
        {"accept", "application/json"}
      ],
      body: URI.encode_query(form_params)
    ]
  end

  defp validate_response(%Req.Response{status: status}) when status in 200..299, do: :ok
  defp validate_response(%Req.Response{status: 401}), do: {:error, :unauthorized}

  defp validate_response(%Req.Response{status: status}) when status >= 500,
    do: {:error, :server_error}

  defp validate_response(%Req.Response{}), do: {:error, :request_failed}

  defp decode_body(body) when is_map(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_response}
    end
  end

  defp decode_body(_body), do: {:error, :invalid_response}

  defp normalize_token_response(
         %{"access_token" => access_token, "expires_in" => expires_in} = body
       )
       when is_binary(access_token) do
    with {:ok, expires_in} <- normalize_expires_in(expires_in) do
      {:ok,
       %{
         access_token: access_token,
         refresh_token: Map.get(body, "refresh_token"),
         expires_in: expires_in,
         token_type: Map.get(body, "token_type")
       }}
    end
  end

  defp normalize_token_response(_body), do: {:error, :invalid_response}

  defp normalize_expires_in(expires_in) when is_integer(expires_in) and expires_in > 0,
    do: {:ok, expires_in}

  defp normalize_expires_in(expires_in) when is_binary(expires_in) do
    case Integer.parse(expires_in) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _invalid -> {:error, :invalid_response}
    end
  end

  defp normalize_expires_in(_expires_in), do: {:error, :invalid_response}

  defp token_url(opts) do
    url = Keyword.get(opts, :token_url) || @default_token_url
    uri = URI.parse(url)

    cond do
      uri.scheme == "https" -> {:ok, url}
      localhost_url?(uri) -> {:ok, url}
      true -> {:error, :invalid_token_url}
    end
  end

  defp localhost_url?(%URI{scheme: "http", host: host})
       when host in ["localhost", "127.0.0.1", "::1"],
       do: true

  defp localhost_url?(_uri), do: false

  defp generate_code_challenge(verifier) do
    verifier
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp generate_state do
    24
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp requester(opts) do
    Keyword.get(opts, :requester, &Req.post/1)
  end

  defp merged_options(opts) do
    Keyword.merge(config(), opts)
  end

  defp config do
    Application.get_env(:elixir_claw, __MODULE__, [])
  end
end
