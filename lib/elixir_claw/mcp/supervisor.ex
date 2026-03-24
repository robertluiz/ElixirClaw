defmodule ElixirClaw.MCP.Supervisor do
  @moduledoc false

  use Supervisor

  require Logger

  def start_link(opts \\ [])

  def start_link(opts) when is_list(opts) do
    Supervisor.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  def start_link(opts) when is_map(opts), do: start_link(Map.to_list(opts))

  def child_specs do
    :elixir_claw
    |> Application.get_env(:mcp_servers, [])
    |> normalize_servers()
    |> Enum.reduce([], fn server_config, acc ->
      case child_spec_for_server(server_config) do
        {:ok, child_spec} ->
          acc ++ [child_spec]

        {:skip, reason} ->
          Logger.warning(reason)
          acc
      end
    end)
  end

  @impl true
  def init(:ok) do
    Supervisor.init(child_specs(), strategy: :one_for_one)
  end

  defp child_spec_for_server(server_config) do
    server_name = server_name(server_config)

    cond do
      is_binary(fetch_value(server_config, :url)) ->
        {:ok,
         %{
           id: {:mcp_http_server, server_name},
           start: {ElixirClaw.MCP.HTTPClient, :connect, [http_client_opts(server_config)]},
           restart: :transient
         }}

      is_binary(fetch_value(server_config, :command)) ->
        {:ok,
         %{
           id: {:mcp_stdio_server, server_name},
           start: {ElixirClaw.MCP.StdioClient, :start_link, [stdio_client_opts(server_config)]},
           restart: :transient
         }}

      true ->
        {:skip,
         "Skipping MCP server startup because runtime config is missing a supported transport"}
    end
  end

  defp http_client_opts(server_config) do
    [url: fetch_value(server_config, :url)]
    |> maybe_put(:timeout, fetch_value(server_config, :timeout))
    |> maybe_put(:connect_timeout, fetch_value(server_config, :connect_timeout))
  end

  defp stdio_client_opts(server_config) do
    command = fetch_value(server_config, :command)
    args = List.wrap(fetch_value(server_config, :args))

    [command: [command | args]]
    |> maybe_put(:cwd, fetch_value(server_config, :cwd))
    |> maybe_put(:env, normalize_env(fetch_value(server_config, :env)))
    |> maybe_put(
      :timeout_ms,
      fetch_value(server_config, :timeout_ms) || fetch_value(server_config, :timeout)
    )
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_servers(servers) when is_list(servers), do: Enum.filter(servers, &is_map/1)

  defp normalize_servers(servers) when is_map(servers) do
    Enum.map(servers, fn
      {name, %{} = config} -> Map.put_new(config, :name, name)
      {_name, _config} -> %{}
    end)
  end

  defp normalize_servers(_servers), do: []

  defp normalize_env(env) when is_map(env), do: Enum.to_list(env)
  defp normalize_env(env) when is_list(env), do: env
  defp normalize_env(_env), do: nil

  defp server_name(config) do
    case fetch_value(config, :name) do
      name when is_binary(name) -> name
      name when is_atom(name) -> Atom.to_string(name)
      _ -> "unnamed"
    end
  end

  defp fetch_value(config, key) when is_map(config) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key))
  end
end
