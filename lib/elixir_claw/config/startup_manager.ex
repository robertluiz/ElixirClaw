defmodule ElixirClaw.Config.StartupManager do
  @moduledoc false

  require Logger

  @allowed_secret_env_suffixes ["_KEY", "_TOKEN", "_SECRET"]

  @provider_required_secrets %{
    "openai" => ["api_key"],
    "anthropic" => ["api_key"],
    "openrouter" => ["api_key"]
  }

  @channel_required_secrets %{
    "telegram" => ["bot_token"],
    "discord" => ["bot_token"]
  }

  @provider_allowed_keys MapSet.new(["enabled", "api_key", "model", "base_url", "name"])
  @channel_allowed_keys MapSet.new(["enabled", "bot_token", "type"])

  @spec enabled_channels(map()) :: [{String.t(), map()}]
  def enabled_channels(config_map) when is_map(config_map) do
    config_map
    |> interpolate_env_vars()
    |> enabled_entries("channels", @channel_allowed_keys, @channel_required_secrets, "channel")
  end

  @spec enabled_providers(map()) :: [{String.t(), map()}]
  def enabled_providers(config_map) when is_map(config_map) do
    config_map
    |> interpolate_env_vars()
    |> enabled_entries(
      "providers",
      @provider_allowed_keys,
      @provider_required_secrets,
      "provider"
    )
  end

  @spec interpolate_env_vars(term()) :: term()
  def interpolate_env_vars(value) when is_list(value),
    do: Enum.map(value, &interpolate_env_vars/1)

  def interpolate_env_vars(%module{} = struct) do
    struct
    |> Map.from_struct()
    |> interpolate_env_vars()
    |> then(&struct(module, &1))
  end

  def interpolate_env_vars(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, nested} -> {key, interpolate_env_vars(nested)} end)
  end

  def interpolate_env_vars(value) when is_binary(value), do: interpolate_string(value)
  def interpolate_env_vars(value), do: value

  @spec validate_required_secrets(map()) :: {:ok, map()} | {:error, [{String.t(), :missing}]}
  def validate_required_secrets(config_map) when is_map(config_map) do
    interpolated = interpolate_env_vars(config_map)

    missing_fields =
      missing_required_fields(interpolated, "providers", @provider_required_secrets) ++
        missing_required_fields(interpolated, "channels", @channel_required_secrets)

    case missing_fields do
      [] -> {:ok, interpolated}
      fields -> {:error, fields}
    end
  end

  defp enabled_entries(config_map, collection_key, allowed_keys, required_secrets, label) do
    config_map
    |> normalize_collection(Map.get(config_map, collection_key))
    |> Enum.reduce([], fn {name, entry}, acc ->
      validate_enabled_type!(collection_key, name, entry)
      warn_unknown_keys(label, name, entry, allowed_keys)

      if Map.get(entry, "enabled", false) do
        case missing_fields_for_entry(collection_key, name, entry, required_secrets) do
          [] ->
            [{name, entry} | acc]

          missing ->
            Logger.warning(
              "Skipping enabled #{label} #{name}: missing required secrets #{format_missing(missing)}"
            )

            acc
        end
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp normalize_collection(_config_map, nil), do: []

  defp normalize_collection(_config_map, values) when is_list(values) do
    values
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn entry ->
      name = Map.get(entry, "name") || Map.get(entry, "type") || "<unknown>"
      {name, entry}
    end)
  end

  defp normalize_collection(_config_map, values) when is_map(values) do
    Enum.map(values, fn
      {name, attrs} when is_map(attrs) -> {name, attrs}
      {name, _attrs} -> {name, %{}}
    end)
  end

  defp normalize_collection(_config_map, _values), do: []

  defp validate_enabled_type!(collection_key, name, entry) do
    case Map.fetch(entry, "enabled") do
      :error -> :ok
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _value} -> raise ArgumentError, "#{collection_key}.#{name}.enabled must be a boolean"
    end
  end

  defp warn_unknown_keys(label, name, entry, allowed_keys) do
    unknown_keys =
      entry
      |> Map.keys()
      |> Enum.filter(&(is_binary(&1) and not MapSet.member?(allowed_keys, &1)))
      |> Enum.sort()

    case unknown_keys do
      [] -> :ok
      keys -> Logger.warning("Unknown config keys for #{label} #{name}: #{Enum.join(keys, ", ")}")
    end
  end

  defp missing_required_fields(config_map, collection_key, required_secrets) do
    config_map
    |> normalize_collection(Map.get(config_map, collection_key))
    |> Enum.flat_map(fn {name, entry} ->
      if Map.get(entry, "enabled", false) do
        missing_fields_for_entry(collection_key, name, entry, required_secrets)
      else
        []
      end
    end)
  end

  defp missing_fields_for_entry(collection_key, name, entry, required_secrets) do
    required_secrets
    |> Map.get(name, [])
    |> Enum.flat_map(fn field ->
      if missing_secret?(Map.get(entry, field)) do
        [{"#{collection_key}.#{name}.#{field}", :missing}]
      else
        []
      end
    end)
  end

  defp missing_secret?(:missing), do: true
  defp missing_secret?(nil), do: true
  defp missing_secret?(""), do: true
  defp missing_secret?(value) when is_binary(value), do: String.trim(value) == ""
  defp missing_secret?(_value), do: false

  defp format_missing(missing_fields) do
    missing_fields
    |> Enum.map(fn {field, _status} -> field end)
    |> Enum.join(", ")
  end

  defp interpolate_string(value) do
    case Regex.run(~r/^\$\{([A-Z0-9_]+)\}$/, value, capture: :all_but_first) do
      [env_var] -> interpolate_exact_env_var(value, env_var)
      _ -> interpolate_inline_env_vars(value)
    end
  end

  defp interpolate_exact_env_var(original, env_var) do
    if allowed_secret_env_var?(env_var) do
      System.get_env(env_var) || :missing
    else
      original
    end
  end

  defp interpolate_inline_env_vars(value) do
    Regex.replace(~r/\$\{([A-Z0-9_]+)\}/, value, fn match, env_var ->
      if allowed_secret_env_var?(env_var) do
        System.get_env(env_var) || match
      else
        match
      end
    end)
  end

  defp allowed_secret_env_var?(env_var) do
    Enum.any?(@allowed_secret_env_suffixes, &String.ends_with?(env_var, &1))
  end
end
