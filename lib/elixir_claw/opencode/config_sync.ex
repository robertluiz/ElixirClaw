defmodule ElixirClaw.OpenCode.ConfigSync do
  @moduledoc false

  @secret_key_patterns ["key", "token", "secret", "password", "credential"]
  @unsafe_command_patterns [";", "&&", "||", "|", ">", "<", "`"]

  @type merged_config :: %{mcp_servers: [map()], skill_paths: [String.t()]}

  @spec sync_config(Path.t(), keyword()) :: {:ok, merged_config()} | {:error, atom()}
  def sync_config(config_path, opts \\ []) do
    with {:ok, parsed} <- load_config(config_path, opts),
         {:ok, mcp_servers} <- build_mcp_servers(parsed),
         {:ok, skill_paths} <- build_skill_paths(parsed) do
      {:ok, %{mcp_servers: mcp_servers, skill_paths: skill_paths}}
    end
  end

  @spec import_mcp_servers(Path.t(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def import_mcp_servers(config_path, opts \\ []) do
    with {:ok, parsed} <- load_config(config_path, opts) do
      build_mcp_servers(parsed)
    end
  end

  @spec import_skill_paths(Path.t(), keyword()) :: {:ok, [String.t()]} | {:error, atom()}
  def import_skill_paths(config_path, opts \\ []) do
    with {:ok, parsed} <- load_config(config_path, opts) do
      build_skill_paths(parsed)
    end
  end

  @spec diff_config(Path.t(), keyword()) :: {:ok, merged_config()} | {:error, atom()}
  def diff_config(config_path, opts \\ []) do
    sync_config(config_path, opts)
  end

  defp load_config(config_path, _opts) do
    case File.read(config_path) do
      {:ok, contents} -> decode_jsonc(contents)
      {:error, :enoent} -> {:error, :config_not_found}
      {:error, _reason} -> {:error, :config_not_found}
    end
  end

  defp decode_jsonc(contents) do
    contents
    |> strip_comments()
    |> Jason.decode()
    |> case do
      {:ok, %{} = config} -> {:ok, Map.drop(config, ["providers"])}
      {:ok, _other} -> {:error, :invalid_json}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp build_mcp_servers(config) do
    servers =
      config
      |> Map.get("mcpServers", %{})
      |> normalize_server_entries()
      |> Enum.reduce([], fn {name, server_config}, acc ->
        case sanitize_server(name, server_config) do
          {:ok, server} -> [server | acc]
          :skip -> acc
        end
      end)
      |> Enum.reverse()

    {:ok, servers}
  end

  defp build_skill_paths(config) do
    skill_paths =
      config
      |> Map.get("skills", %{})
      |> Map.get("paths", [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    {:ok, skill_paths}
  end

  defp normalize_server_entries(servers) when is_map(servers) do
    Enum.filter(servers, fn
      {name, config} when is_binary(name) and is_map(config) -> true
      _ -> false
    end)
  end

  defp normalize_server_entries(_servers), do: []

  defp sanitize_server(name, server_config) do
    sanitized =
      server_config
      |> Map.drop(["env"])
      |> reject_secret_keys()

    cond do
      is_binary(sanitized["command"]) -> sanitize_stdio_server(name, sanitized)
      is_binary(sanitized["url"]) -> sanitize_http_server(name, sanitized)
      true -> :skip
    end
  end

  defp sanitize_stdio_server(name, %{"command" => command} = server_config) do
    if safe_command?(command) do
      {:ok,
       %{
         name: name,
         transport: "stdio",
         command: command,
         args: normalize_args(Map.get(server_config, "args", []))
       }}
    else
      :skip
    end
  end

  defp sanitize_http_server(name, %{"url" => url}) do
    {:ok, %{name: name, transport: "http", url: url}}
  end

  defp normalize_args(args) when is_list(args), do: Enum.filter(args, &is_binary/1)
  defp normalize_args(_args), do: []

  defp reject_secret_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      if secret_like_key?(key) do
        acc
      else
        Map.put(acc, key, sanitize_nested_value(value))
      end
    end)
  end

  defp sanitize_nested_value(value) when is_map(value), do: reject_secret_keys(value)
  defp sanitize_nested_value(value) when is_list(value), do: Enum.map(value, &sanitize_nested_value/1)
  defp sanitize_nested_value(value), do: value

  defp secret_like_key?(key) when is_binary(key) do
    normalized_key = String.downcase(key)
    Enum.any?(@secret_key_patterns, &String.contains?(normalized_key, &1))
  end

  defp secret_like_key?(_key), do: false

  defp safe_command?(command) when is_binary(command) do
    Enum.all?(@unsafe_command_patterns, &(not String.contains?(command, &1)))
  end

  defp strip_comments(contents) do
    contents
    |> String.to_charlist()
    |> do_strip_comments([], :code)
    |> Enum.reverse()
    |> List.to_string()
  end

  defp do_strip_comments([], acc, _state), do: acc

  defp do_strip_comments([?/ , ?/ | rest], acc, :code), do: skip_line_comment(rest, acc)
  defp do_strip_comments([?/ , ?* | rest], acc, :code), do: skip_block_comment(rest, acc)
  defp do_strip_comments([?" | rest], acc, :code), do: do_strip_comments(rest, [?" | acc], :string)
  defp do_strip_comments([char | rest], acc, :code), do: do_strip_comments(rest, [char | acc], :code)

  defp do_strip_comments([?\\, char | rest], acc, :string),
    do: do_strip_comments(rest, [char, ?\\ | acc], :string)

  defp do_strip_comments([?" | rest], acc, :string), do: do_strip_comments(rest, [?" | acc], :code)
  defp do_strip_comments([char | rest], acc, :string), do: do_strip_comments(rest, [char | acc], :string)

  defp skip_line_comment([], acc), do: acc
  defp skip_line_comment([?\n | rest], acc), do: do_strip_comments(rest, [?\n | acc], :code)
  defp skip_line_comment([?\r, ?\n | rest], acc), do: do_strip_comments(rest, [?\n, ?\r | acc], :code)
  defp skip_line_comment([_char | rest], acc), do: skip_line_comment(rest, acc)

  defp skip_block_comment([], acc), do: acc
  defp skip_block_comment([?*, ?/ | rest], acc), do: do_strip_comments(rest, acc, :code)
  defp skip_block_comment([_char | rest], acc), do: skip_block_comment(rest, acc)
end
