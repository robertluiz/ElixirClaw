import Config

atomize_keys = fn atomize_keys, map ->
  Enum.into(map, [], fn
    {key, value} when is_binary(key) and is_map(value) ->
      {String.to_atom(key), atomize_keys.(atomize_keys, value)}

    {key, value} when is_binary(key) and is_list(value) ->
      {String.to_atom(key), Enum.map(value, fn item -> if is_map(item), do: atomize_keys.(atomize_keys, item), else: item end)}

    {key, value} when is_binary(key) ->
      {String.to_atom(key), value}

    {key, value} when is_atom(key) and is_map(value) ->
      {key, atomize_keys.(atomize_keys, value)}

    {key, value} when is_atom(key) and is_list(value) ->
      {key, Enum.map(value, fn item -> if is_map(item), do: atomize_keys.(atomize_keys, item), else: item end)}

    {key, value} ->
      {key, value}
  end)
end

provider_module = fn
  "openai" -> ElixirClaw.Providers.OpenAI
  "anthropic" -> ElixirClaw.Providers.Anthropic
  "openrouter" -> ElixirClaw.Providers.OpenRouter
  "copilot" -> ElixirClaw.Providers.Copilot.Client
  "github_copilot" -> ElixirClaw.Providers.Copilot.Client
  "copilot_byok" -> ElixirClaw.Providers.CopilotBYOK
  "codex" -> ElixirClaw.Providers.Codex.Client
  _provider_name -> nil
end

normalize_provider_attrs = fn attrs ->
  attrs = atomize_keys.(atomize_keys, attrs)

  cond do
    match?([_ | _], Keyword.get(attrs, :models)) and not is_binary(Keyword.get(attrs, :model)) ->
      Keyword.put(attrs, :model, List.first(Keyword.get(attrs, :models)))

    match?([_ | _], Keyword.get(attrs, :model)) ->
      models = Keyword.get(attrs, :model)

      attrs
      |> Keyword.put(:models, models)
      |> Keyword.put(:model, List.first(models))

    true ->
      attrs
  end
end

default_provider_name = fn provider_names ->
  case provider_names do
    [single] -> single
    names when is_list(names) ->
      cond do
        Enum.member?(names, "openai") -> "openai"
        Enum.member?(names, "github_copilot") -> "github_copilot"
        Enum.member?(names, "copilot") -> "copilot"
        Enum.member?(names, "codex") -> "codex"
        true -> names |> Enum.sort() |> List.first()
      end

    [] -> nil
    _other -> nil
  end
end

default_model = fn attrs ->
  normalized = normalize_provider_attrs.(attrs)

  cond do
    is_binary(Keyword.get(normalized, :model)) and String.trim(Keyword.get(normalized, :model)) != "" ->
      Keyword.get(normalized, :model)

    match?([_ | _], Keyword.get(normalized, :models)) ->
      List.first(Keyword.get(normalized, :models))

    true ->
      nil
  end
end

config_path = Path.expand("config/config.toml", __DIR__ <> "/..")

if File.exists?(config_path) do
  case Toml.decode_file(config_path) do
    {:ok, raw_config} ->
      interpolated = ElixirClaw.Config.StartupManager.interpolate_env_vars(raw_config)

      enabled_providers = ElixirClaw.Config.StartupManager.enabled_providers(interpolated)
      provider_entries = if(enabled_providers == [], do: Map.to_list(Map.get(interpolated, "providers", %{})), else: enabled_providers)
      configured_provider_names = Enum.map(provider_entries, &elem(&1, 0))
      selected_default_provider = default_provider_name.(configured_provider_names)
      selected_default_model =
        provider_entries
        |> Enum.find_value(fn
          {name, attrs} when name == selected_default_provider -> default_model.(attrs)
          _other -> nil
        end)

      enabled_channels = ElixirClaw.Config.StartupManager.enabled_channels(interpolated)
      enabled_channel_names = MapSet.new(Enum.map(enabled_channels, &elem(&1, 0)))

      channels_config =
        interpolated
        |> Map.get("channels", %{})
        |> Enum.into(%{}, fn
          {name, attrs} when is_binary(name) and is_map(attrs) ->
            {String.to_atom(name), atomize_keys.(atomize_keys, attrs)}

          {name, attrs} when is_atom(name) and is_map(attrs) ->
            {name, atomize_keys.(atomize_keys, attrs)}
        end)

      for {provider_name, attrs} <- Map.get(interpolated, "providers", %{}) do
        if module = provider_module.(provider_name) do
          config :elixir_claw, module, normalize_provider_attrs.(attrs)
        end
      end

      config :elixir_claw, :channels, channels_config
      config :elixir_claw, :configured_providers, configured_provider_names
      config :elixir_claw, :cli_enabled, MapSet.member?(enabled_channel_names, "cli")
      config :elixir_claw, :telegram_enabled, MapSet.member?(enabled_channel_names, "telegram")
      config :elixir_claw, :discord_enabled, MapSet.member?(enabled_channel_names, "discord")

      if is_binary(selected_default_provider) and String.trim(selected_default_provider) != "" do
        config :elixir_claw, :default_provider, selected_default_provider
      end

      if is_binary(selected_default_model) and String.trim(selected_default_model) != "" do
        config :elixir_claw, :default_model, selected_default_model
      end

      if database_path = get_in(interpolated, ["database", "database_path"]) do
        config :elixir_claw, ElixirClaw.Repo, path: database_path
      end

      configured_skill_paths =
        [get_in(interpolated, ["skills", "skills_dir"]), get_in(interpolated, ["skills", "paths"])]
        |> List.flatten()

      resolved_skill_paths = ElixirClaw.Skills.Paths.resolve(configured_skill_paths)

      case resolved_skill_paths do
        [] ->
          :ok

        [primary | _] ->
          config :elixir_claw, :skills_dir, primary
          config :elixir_claw, :skill_paths, resolved_skill_paths
      end

    {:error, reason} ->
      IO.warn("Failed to load config/config.toml: #{inspect(reason)}")
  end
end
