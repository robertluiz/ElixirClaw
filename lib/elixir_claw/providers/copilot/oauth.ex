defmodule ElixirClaw.Providers.Copilot.OAuth do
  @moduledoc """
  OAuth helpers for the GitHub Copilot device authorization flow.
  """

  @default_device_code_url "https://github.com/login/device/code"
  @default_token_url "https://github.com/login/oauth/access_token"
  @default_scope "read:user"

  @type device_code_response :: %{
          device_code: String.t(),
          user_code: String.t(),
          verification_uri: String.t(),
          expires_in: pos_integer(),
          interval: pos_integer()
        }

  @type token_response :: %{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          token_type: String.t() | nil,
          scope: String.t() | nil,
          expires_in: pos_integer() | nil,
          refresh_token_expires_in: pos_integer() | nil
        }

  @spec device_code(keyword()) :: {:ok, device_code_response()} | {:error, term()}
  def device_code(opts \\ []) when is_list(opts) do
    opts = merged_options(opts)

    request_form(
      [
        {"client_id", Keyword.fetch!(opts, :client_id)},
        {"scope", Keyword.get(opts, :scope, @default_scope)}
      ],
      device_code_url(opts),
      &normalize_device_code_response/1,
      opts
    )
  end

  @spec poll_device_token(String.t(), keyword()) :: {:ok, token_response()} | {:error, term()}
  def poll_device_token(device_code, opts \\ [])
      when is_binary(device_code) and is_list(opts) do
    opts = merged_options(opts)

    do_poll_device_token(device_code, DateTime.add(DateTime.utc_now(), poll_timeout(opts), :millisecond), opts)
  end

  @spec refresh_token(String.t(), keyword()) :: {:ok, token_response()} | {:error, term()}
  def refresh_token(refresh_token, opts \\ []) when is_binary(refresh_token) and is_list(opts) do
    opts = merged_options(opts)

    request_form(
      [
        {"client_id", Keyword.fetch!(opts, :client_id)},
        {"grant_type", "refresh_token"},
        {"refresh_token", refresh_token}
      ],
      token_url(opts),
      &normalize_token_response/1,
      opts
    )
  end

  @spec refresh_token_override(String.t(), keyword()) :: {:ok, token_response()} | {:error, term()}
  def refresh_token_override(refresh_token, opts \\ []) when is_binary(refresh_token) and is_list(opts) do
    merged_options(opts)
    |> Keyword.get(:refresh_token)
    |> case do
      refresh_override when is_function(refresh_override, 2) ->
        refresh_override.(refresh_token, opts)

      _missing_override ->
        refresh_token(refresh_token, opts)
    end
  end

  defp request_form(form_params, url, normalizer, opts) do
    with {:ok, response} <- requester(opts).(request_options(url, form_params)),
         :ok <- validate_response(response),
         {:ok, body} <- decode_body(response.body),
         {:ok, normalized} <- normalizer.(body) do
      {:ok, normalized}
    else
      {:error, _reason} = error -> error
    end
  end

  defp request_options(url, form_params) do
    [
      url: url,
      headers: [
        {"content-type", "application/x-www-form-urlencoded"},
        {"accept", "application/json"}
      ],
      body: URI.encode_query(form_params)
    ]
  end

  defp validate_response(%Req.Response{status: status}) when status in 200..299, do: :ok
  defp validate_response(%Req.Response{status: 401}), do: {:error, :unauthorized}
  defp validate_response(%Req.Response{status: status}) when status >= 500, do: {:error, :server_error}
  defp validate_response(%Req.Response{}), do: {:error, :request_failed}

  defp decode_body(body) when is_map(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_response}
    end
  end

  defp decode_body(_body), do: {:error, :invalid_response}

  defp normalize_device_code_response(%{
         "device_code" => device_code,
         "user_code" => user_code,
         "verification_uri" => verification_uri,
         "expires_in" => expires_in,
         "interval" => interval
       }) do
    with {:ok, expires_in} <- normalize_positive_integer(expires_in),
         {:ok, interval} <- normalize_positive_integer(interval) do
      {:ok,
       %{
         device_code: device_code,
         user_code: user_code,
         verification_uri: verification_uri,
         expires_in: expires_in,
         interval: interval
       }}
    end
  end

  defp normalize_device_code_response(_body), do: {:error, :invalid_response}

  defp normalize_token_response(%{"access_token" => access_token} = body)
       when is_binary(access_token) do
    with {:ok, expires_in} <- normalize_optional_positive_integer(Map.get(body, "expires_in")),
         {:ok, refresh_token_expires_in} <-
           normalize_optional_positive_integer(Map.get(body, "refresh_token_expires_in")) do
      {:ok,
       %{
         access_token: access_token,
         refresh_token: Map.get(body, "refresh_token"),
         token_type: Map.get(body, "token_type"),
         scope: Map.get(body, "scope"),
         expires_in: expires_in,
         refresh_token_expires_in: refresh_token_expires_in
       }}
    end
  end

  defp normalize_token_response(%{"error" => "authorization_pending"}),
    do: {:error, :authorization_pending}

  defp normalize_token_response(%{"error" => "slow_down"}), do: {:error, :slow_down}
  defp normalize_token_response(%{"error" => "expired_token"}), do: {:error, :expired_token}
  defp normalize_token_response(%{"error" => "access_denied"}), do: {:error, :access_denied}

  defp normalize_token_response(_body), do: {:error, :invalid_response}

  defp do_poll_device_token(device_code, deadline, opts) do
    if DateTime.compare(DateTime.utc_now(), deadline) == :gt do
      {:error, :poll_timeout}
    else
      case request_form(
             [
               {"client_id", Keyword.fetch!(opts, :client_id)},
               {"device_code", device_code},
               {"grant_type", "urn:ietf:params:oauth:grant-type:device_code"}
             ],
             token_url(opts),
             &normalize_token_response/1,
             opts
           ) do
        {:ok, token_response} ->
          {:ok, token_response}

        {:error, :authorization_pending} ->
          sleep(opts, poll_interval(opts))
          do_poll_device_token(device_code, deadline, opts)

        {:error, :slow_down} ->
          sleep(opts, poll_interval(opts) * 2)
          do_poll_device_token(device_code, deadline, opts)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _invalid -> {:error, :invalid_response}
    end
  end

  defp normalize_positive_integer(_value), do: {:error, :invalid_response}

  defp normalize_optional_positive_integer(nil), do: {:ok, nil}
  defp normalize_optional_positive_integer(value), do: normalize_positive_integer(value)

  defp device_code_url(opts), do: Keyword.get(opts, :device_code_url, @default_device_code_url)
  defp token_url(opts), do: Keyword.get(opts, :token_url, @default_token_url)
  defp requester(opts), do: Keyword.get(opts, :requester, &Req.post/1)
  defp poll_interval(opts), do: Keyword.get(opts, :interval, 5) * 1_000
  defp poll_timeout(opts), do: Keyword.get(opts, :poll_timeout_ms, 900_000)
  defp sleep(opts, duration_ms), do: Keyword.get(opts, :sleep, &Process.sleep/1).(duration_ms)
  defp merged_options(opts), do: Keyword.merge(config(), opts)
  defp config, do: Application.get_env(:elixir_claw, __MODULE__, [])
end
