defmodule ElixirClaw.Providers.OAuthTokenStore do
  @moduledoc false

  @app :elixir_claw

  @spec load(String.t(), keyword()) :: map()
  def load(provider_name, opts \\ []) when is_binary(provider_name) and is_list(opts) do
    provider_name
    |> token_path(opts)
    |> File.read()
    |> case do
      {:ok, contents} -> decode_token(contents)
      {:error, _reason} -> %{}
    end
  end

  @spec persist(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def persist(provider_name, token_data, opts \\ [])
      when is_binary(provider_name) and is_map(token_data) and is_list(opts) do
    path = token_path(provider_name, opts)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, payload} <- encode_token(token_data),
         :ok <- File.write(path, payload) do
      :ok
    end
  end

  @spec clear(String.t(), keyword()) :: :ok
  def clear(provider_name, opts \\ []) when is_binary(provider_name) and is_list(opts) do
    case File.rm(token_path(provider_name, opts)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp encode_token(token_data) do
    token_data
    |> Map.update(:expires_at, nil, &encode_datetime/1)
    |> Jason.encode()
  end

  defp decode_token(contents) do
    with {:ok, decoded} <- Jason.decode(contents) do
      if is_map(decoded) do
        decoded
        |> Enum.into(%{}, fn {key, value} -> {normalize_key(key), value} end)
        |> Map.update(:expires_at, nil, &decode_datetime/1)
      else
        %{}
      end
    else
      _error -> %{}
    end
  end

  defp normalize_key("access_token"), do: :access_token
  defp normalize_key("refresh_token"), do: :refresh_token
  defp normalize_key("expires_at"), do: :expires_at
  defp normalize_key(key), do: key

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(other), do: other

  defp decode_datetime(nil), do: nil

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp decode_datetime(_value), do: nil

  defp token_path(provider_name, opts) do
    Keyword.get_lazy(opts, :storage_path, fn ->
      Application.get_env(@app, __MODULE__, [])
      |> Keyword.get_lazy(:storage_path, fn ->
        Path.join([System.user_home!(), ".elixir_claw", "oauth", "#{provider_name}.json"])
      end)
    end)
  end
end
