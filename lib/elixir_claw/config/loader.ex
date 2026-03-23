defmodule ElixirClaw.Config.Loader do
  @moduledoc false

  alias ElixirClaw.Config

  @default_max_context_tokens 4096
  @default_summarization_threshold 0.6
  @default_skill_token_budget 1024
  @default_rate_limit 60
  @placeholder_secret "YOUR_KEY_HERE"

  def load(path) when is_binary(path) do
    case Toml.decode_file(path) do
      {:ok, data} -> build_config(data)
      {:error, reason} -> {:error, List.wrap(format_reason(reason))}
    end
  end

  def load_from_string(contents) when is_binary(contents) do
    case Toml.decode(contents) do
      {:ok, data} -> build_config(data)
      {:error, reason} -> {:error, List.wrap(format_reason(reason))}
    end
  end

  defp build_config(raw) when is_map(raw) do
    interpolated = interpolate_env(raw)

    providers = normalize_collection(Map.get(interpolated, "providers"), "name")
    channels = normalize_collection(Map.get(interpolated, "channels"), "type")
    mcp_servers = normalize_collection(Map.get(interpolated, "mcp_servers"), "name")

    config = %Config{
      providers: Enum.map(providers, &Config.Provider.new/1),
      channels: channels,
      database_path: nested_or_root(interpolated, ["database", "database_path"], "database_path"),
      skills_dir: nested_or_root(interpolated, ["skills", "skills_dir"], "skills_dir"),
      max_context_tokens:
        nested_or_root(interpolated, ["context", "max_context_tokens"], "max_context_tokens") ||
          @default_max_context_tokens,
      summarization_threshold:
        nested_or_root(
          interpolated,
          ["context", "summarization_threshold"],
          "summarization_threshold"
        ) ||
          @default_summarization_threshold,
      skill_token_budget:
        nested_or_root(interpolated, ["context", "skill_token_budget"], "skill_token_budget") ||
          @default_skill_token_budget,
      rate_limit:
        nested_or_root(interpolated, ["rate_limit", "max_requests_per_minute"], "rate_limit") ||
          @default_rate_limit,
      mcp_servers: mcp_servers,
      security: Map.get(interpolated, "security", %{})
    }

    case validate(config, interpolated) do
      [] -> {:ok, config}
      reasons -> {:error, reasons}
    end
  rescue
    error -> {:error, [Exception.message(error)]}
  end

  defp validate(%Config{} = config, raw) do
    []
    |> validate_required_list(config.providers, "providers")
    |> validate_required_list(config.channels, "channels")
    |> validate_required_string(config.database_path, "database_path")
    |> validate_integer_range(config.max_context_tokens, "max_context_tokens", 256, 1_000_000)
    |> validate_integer_range(config.rate_limit, "rate_limit", 1, 10_000)
    |> validate_provider_api_keys(config.providers)
    |> validate_collection_shape(Map.get(raw, "providers"), "providers")
    |> validate_collection_shape(Map.get(raw, "channels"), "channels")
    |> validate_collection_shape(Map.get(raw, "mcp_servers"), "mcp_servers")
    |> Enum.reverse()
  end

  defp validate_required_list(reasons, value, _field) when is_list(value) and value != [],
    do: reasons

  defp validate_required_list(reasons, _value, field),
    do: ["#{field} is required and must be a non-empty list" | reasons]

  defp validate_required_string(reasons, value, field)
       when is_binary(value) and byte_size(value) > 0 do
    if byte_size(String.trim(value)) > 0,
      do: reasons,
      else: ["#{field} is required and must be a non-empty string" | reasons]
  end

  defp validate_required_string(reasons, _value, field),
    do: ["#{field} is required and must be a non-empty string" | reasons]

  defp validate_integer_range(reasons, value, _field, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: reasons

  defp validate_integer_range(reasons, _value, field, min, max),
    do: ["#{field} must be an integer between #{min} and #{max}" | reasons]

  defp validate_provider_api_keys(reasons, providers) do
    Enum.reduce(providers, reasons, fn provider, acc ->
      api_key = provider.api_key

      cond do
        not is_binary(api_key) or String.trim(api_key) == "" ->
          ["provider #{provider.name || "<unknown>"} api_key must be a non-empty string" | acc]

        String.trim(api_key) == @placeholder_secret ->
          [
            "provider #{provider.name || "<unknown>"} api_key cannot be #{@placeholder_secret}"
            | acc
          ]

        true ->
          acc
      end
    end)
  end

  defp validate_collection_shape(reasons, nil, _field), do: reasons

  defp validate_collection_shape(reasons, value, _field) when is_list(value) or is_map(value),
    do: reasons

  defp validate_collection_shape(reasons, _value, field),
    do: ["#{field} must be a table or array of tables" | reasons]

  defp normalize_collection(nil, _identity_key), do: []

  defp normalize_collection(values, _identity_key) when is_list(values) do
    Enum.filter(values, &is_map/1)
  end

  defp normalize_collection(values, identity_key) when is_map(values) do
    Enum.map(values, fn
      {name, attrs} when is_map(attrs) -> Map.put_new(attrs, identity_key, name)
      {_name, _attrs} -> %{}
    end)
  end

  defp normalize_collection(_values, _identity_key), do: []

  defp nested_or_root(raw, path, root_key) do
    get_nested(raw, path) || Map.get(raw, root_key)
  end

  defp get_nested(value, []), do: value
  defp get_nested(value, _path) when not is_map(value), do: nil

  defp get_nested(value, [key | rest]) do
    value
    |> Map.get(key)
    |> get_nested(rest)
  end

  defp interpolate_env(value) when is_list(value), do: Enum.map(value, &interpolate_env/1)

  defp interpolate_env(%module{} = struct) do
    struct
    |> Map.from_struct()
    |> interpolate_env()
    |> then(&struct(module, &1))
  end

  defp interpolate_env(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, nested} -> {key, interpolate_env(nested)} end)
  end

  defp interpolate_env(value) when is_binary(value) do
    Regex.replace(~r/\$\{([A-Z0-9_]+)\}/, value, fn _match, env_var ->
      System.get_env(env_var) || ""
    end)
  end

  defp interpolate_env(value), do: value

  defp format_reason({:invalid_toml, reason}), do: reason
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
