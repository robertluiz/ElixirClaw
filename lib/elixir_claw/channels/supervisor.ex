defmodule ElixirClaw.Channels.Supervisor do
  @moduledoc false

  use Supervisor

  require Logger

  @telegram_token_pattern ~r/^\d+:[A-Za-z0-9_-]+$/

  def start_link(opts \\ [])

  def start_link(opts) when is_list(opts) do
    Supervisor.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  def start_link(opts) when is_map(opts), do: start_link(Map.to_list(opts))

  def child_specs do
    channels_config = Application.get_env(:elixir_claw, :channels, %{})

    []
    |> maybe_add_cli(channels_config)
    |> maybe_add_telegram(channels_config)
    |> maybe_add_discord(channels_config)
  end

  @impl true
  def init(:ok) do
    children = child_specs()

    channels =
      children
      |> Enum.map(&channel_name/1)
      |> case do
        [] -> "none"
        names -> Enum.join(names, ",")
      end

    Logger.info("Starting ElixirClaw.Channels.Supervisor with channels: #{channels}")

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp maybe_add_cli(children, channels_config) do
    if Application.get_env(:elixir_claw, :cli_enabled, true) do
      [
        channel_child_spec(ElixirClaw.Channels.CLI, channel_config(channels_config, :cli))
        | children
      ]
    else
      children
    end
  end

  defp maybe_add_telegram(children, channels_config) do
    if Application.get_env(:elixir_claw, :telegram_enabled, false) do
      config = channel_config(channels_config, :telegram)

      if valid_telegram_config?(config) do
        children ++ [channel_child_spec(ElixirClaw.Channels.Telegram, config)]
      else
        Logger.warning(
          "Skipping Telegram channel startup because required runtime config is missing or invalid"
        )

        children
      end
    else
      children
    end
  end

  defp maybe_add_discord(children, channels_config) do
    if Application.get_env(:elixir_claw, :discord_enabled, false) do
      children ++
        [
          channel_child_spec(
            ElixirClaw.Channels.Discord,
            channel_config(channels_config, :discord)
          )
        ]
    else
      children
    end
  end

  defp channel_child_spec(module, config) do
    Supervisor.child_spec({module, config}, id: module, restart: :transient)
  end

  defp valid_telegram_config?(config) do
    case fetch_value(config, :bot_token) do
      token when is_binary(token) -> Regex.match?(@telegram_token_pattern, token)
      _missing -> false
    end
  end

  defp channel_config(config, channel) do
    config
    |> normalize_channels_config()
    |> Map.get(channel, %{})
    |> normalize_mapish()
  end

  defp normalize_channels_config(config) when is_map(config) do
    Enum.reduce([:cli, :telegram, :discord], %{}, fn channel, acc ->
      case fetch_value(config, channel) do
        nil -> acc
        value -> Map.put(acc, channel, normalize_mapish(value))
      end
    end)
  end

  defp normalize_channels_config(config) when is_list(config) do
    if Keyword.keyword?(config) do
      config
      |> Enum.into(%{})
      |> normalize_channels_config()
    else
      Enum.reduce(config, %{}, fn
        %{} = channel_config, acc ->
          case channel_type(channel_config) do
            nil -> acc
            channel -> Map.put(acc, channel, normalize_mapish(channel_config))
          end

        _other, acc ->
          acc
      end)
    end
  end

  defp normalize_channels_config(_config), do: %{}

  defp normalize_mapish(config) when is_map(config), do: config

  defp normalize_mapish(config) when is_list(config) do
    if Keyword.keyword?(config), do: Enum.into(config, %{}), else: %{}
  end

  defp normalize_mapish(_config), do: %{}

  defp channel_type(config) do
    case fetch_value(config, :type) || fetch_value(config, :name) do
      type when type in [:cli, :telegram, :discord] -> type
      type when is_binary(type) -> binary_channel_type(type)
      _ -> nil
    end
  end

  defp binary_channel_type("cli"), do: :cli
  defp binary_channel_type("telegram"), do: :telegram
  defp binary_channel_type("discord"), do: :discord
  defp binary_channel_type(_type), do: nil

  defp fetch_value(config, key) when is_map(config) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key))
  end

  defp channel_name(%{start: {ElixirClaw.Channels.CLI, _, _}}), do: "cli"
  defp channel_name(%{start: {ElixirClaw.Channels.Telegram, _, _}}), do: "telegram"
  defp channel_name(%{start: {ElixirClaw.Channels.Discord, _, _}}), do: "discord"
  defp channel_name(_child), do: "unknown"
end
