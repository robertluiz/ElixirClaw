defmodule ElixirClaw.Providers.Copilot.NodeBridge do
  @moduledoc false

  @app :elixir_claw

  alias ElixirClaw.Providers.Copilot.TokenManager
  alias ElixirClaw.Types.ProviderResponse

  @type request_payload :: %{
          required(String.t()) => term()
        }

  @spec chat([map()], keyword()) :: {:ok, ProviderResponse.t()} | {:error, term()}
  def chat(messages, opts) when is_list(messages) and is_list(opts) do
    request("chat", messages, opts)
  end

  @spec stream([map()], keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(messages, opts) when is_list(messages) and is_list(opts) do
    with {:ok, %ProviderResponse{} = response} <- request("chat", messages, opts) do
      {:ok,
       [
         %{
           delta: response.content || "",
           finish_reason: response.finish_reason,
           tool_calls: response.tool_calls || [],
           token_usage: response.token_usage
         }
       ]
       |> Stream.map(& &1)}
    end
  end

  @spec bridge_script_path() :: String.t()
  def bridge_script_path do
    Path.join([priv_dir(), "copilot_bridge", "index.mjs"])
    |> Path.expand()
  end

  @spec bridge_cwd() :: String.t()
  def bridge_cwd do
    bridge_script_path()
    |> Path.dirname()
  end

  defp request(action, messages, opts) do
    config = config()
    runner = Keyword.get(config, :command_runner, &default_command_runner/1)
    github_token = fetch_github_token(config)

    if is_nil(github_token) or github_token == "" do
      {:error, :no_token}
    else
      do_request(action, messages, opts, config, runner, github_token)
    end
  end

  defp do_request(action, messages, opts, config, runner, github_token) do
    payload =
      %{
        "action" => action,
        "githubToken" => github_token,
        "model" => Keyword.get(opts, :model),
        "reasoningEffort" => Keyword.get(opts, :reasoning_effort),
        "messages" => messages,
        "provider" => "github_copilot"
      }
      |> Map.merge(serialized_message_payload(messages))

    command = bridge_command(config)

    with {:ok, raw_output} <-
           runner.(%{
             command: command,
             input: Jason.encode!(payload),
             env: bridge_env(config),
             cwd: bridge_cwd()
           }),
         {:ok, decoded} <- decode_bridge_output(raw_output),
         {:ok, response} <- normalize_bridge_response(decoded, Keyword.get(opts, :model)) do
      {:ok, response}
    else
      {:error, raw_output} when is_binary(raw_output) ->
        case decode_bridge_output(raw_output) do
          {:ok, decoded} -> normalize_bridge_response(decoded, Keyword.get(opts, :model))
          {:error, _reason} -> {:error, raw_output}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_bridge_output(output) when is_binary(output) do
    output
    |> String.split(["\r\n", "\n"], trim: true)
    |> List.last()
    |> case do
      nil -> {:error, :bridge_no_response}
      line -> Jason.decode(line)
    end
  end

  defp normalize_bridge_response(%{"ok" => true} = decoded, requested_model) do
    {:ok,
     %ProviderResponse{
       content: Map.get(decoded, "content"),
       tool_calls: Map.get(decoded, "tool_calls", []),
       token_usage: Map.get(decoded, "token_usage"),
       model: Map.get(decoded, "model") || requested_model,
       finish_reason: Map.get(decoded, "finish_reason")
     }}
  end

  defp normalize_bridge_response(%{"ok" => false, "error" => reason}, _requested_model),
    do: {:error, normalize_error(reason)}

  defp normalize_bridge_response(_decoded, _requested_model), do: {:error, :invalid_response}

  defp normalize_error(reason) when is_binary(reason) do
    case reason do
      "no_token" ->
        :no_token

      "unauthorized" ->
        :unauthorized

      "request_failed" ->
        :request_failed

      "Execution failed: Error: Session was not created with authentication info or custom provider" ->
        :no_token

      other ->
        other
    end
  end

  defp normalize_error(reason), do: reason

  defp serialized_message_payload(messages) do
    %{}
    |> maybe_put("systemPrompt", system_prompt_from_messages(messages))
    |> maybe_put("prompt", prompt_from_messages(messages))
    |> maybe_put("attachments", attachments_from_messages(messages))
  end

  defp system_prompt_from_messages(messages) do
    messages
    |> Enum.filter(&(message_role(&1) == "system"))
    |> Enum.map(&(message_content(&1) |> serialize_content_for_prompt()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> empty_to_nil()
  end

  defp prompt_from_messages(messages) do
    messages
    |> Enum.filter(&(message_role(&1) != "system"))
    |> Enum.map(fn message ->
      role = message_role(message) || "user"
      content = message_content(message) |> serialize_content_for_prompt()
      "#{role}: #{content}"
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> empty_to_nil()
  end

  defp attachments_from_messages(messages) do
    messages
    |> Enum.filter(&(message_role(&1) == "user"))
    |> Enum.flat_map(&(message_content(&1) |> attachments_from_content()))
    |> case do
      [] -> nil
      attachments -> attachments
    end
  end

  defp serialize_content_for_prompt(content) when is_binary(content), do: content

  defp serialize_content_for_prompt(content) when is_list(content) do
    content
    |> Enum.map(&prompt_part_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp serialize_content_for_prompt(_content), do: ""

  defp prompt_part_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp prompt_part_text(%{type: "text", text: text}) when is_binary(text), do: text
  defp prompt_part_text(%{"type" => "image_url"}), do: "[Image attached]"
  defp prompt_part_text(%{type: "image_url"}), do: "[Image attached]"
  defp prompt_part_text(_part), do: ""

  defp attachments_from_content(content) when is_list(content) do
    content
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {part, index} ->
      case image_attachment_from_part(part, index) do
        nil -> []
        attachment -> [attachment]
      end
    end)
  end

  defp attachments_from_content(_content), do: []

  defp image_attachment_from_part(%{"type" => "image_url", "image_url" => image_url}, index)
       when is_map(image_url),
       do: image_attachment_from_url(Map.get(image_url, "url"), index)

  defp image_attachment_from_part(%{type: "image_url", image_url: image_url}, index)
       when is_map(image_url),
       do: image_attachment_from_url(Map.get(image_url, :url), index)

  defp image_attachment_from_part(_part, _index), do: nil

  defp image_attachment_from_url(url, index) when is_binary(url) do
    case Regex.named_captures(~r/^data:(?<mime>[^;]+);base64,(?<data>.+)$/s, url) do
      %{"mime" => mime_type, "data" => data} ->
        %{
          "type" => "blob",
          "data" => data,
          "mimeType" => mime_type,
          "displayName" => "image-#{index}.#{mime_extension(mime_type)}"
        }

      _other ->
        nil
    end
  end

  defp image_attachment_from_url(_url, _index), do: nil

  defp mime_extension("image/jpeg"), do: "jpeg"
  defp mime_extension("image/png"), do: "png"
  defp mime_extension("image/webp"), do: "webp"
  defp mime_extension("image/gif"), do: "gif"
  defp mime_extension(_mime_type), do: "bin"

  defp message_role(message), do: Map.get(message, :role) || Map.get(message, "role")
  defp message_content(message), do: Map.get(message, :content) || Map.get(message, "content")

  defp empty_to_nil(value) when value in [nil, ""], do: nil
  defp empty_to_nil(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp default_command_runner(%{command: [executable | args], input: input, env: env, cwd: cwd}) do
    with {:ok, port_spec, port_options} <- build_port_command(executable, args, env, cwd),
         {:ok, output, status} <- run_port_command(port_spec, port_options, input) do
      if status == 0, do: {:ok, output}, else: {:error, output}
    end
  end

  defp build_port_command(executable, args, env, cwd) do
    resolved = resolve_executable(executable)

    if is_nil(resolved) do
      {:error, :command_not_found}
    else
      {:ok, {:spawn_executable, resolved},
       [
         :binary,
         :exit_status,
         :use_stdio,
         :stderr_to_stdout,
         :hide,
         args: args,
         cd: cwd,
         env: Enum.map(env, &env_entry_to_charlist/1)
       ]}
    end
  end

  defp run_port_command(spec, options, input) do
    port = Port.open(spec, options)

    try do
      true = Port.command(port, input <> "\n")
      collect_port_output(port, [])
    after
      if Port.info(port) != nil do
        Port.close(port)
      end
    end
  end

  defp collect_port_output(port, chunks) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, [data | chunks])

      {^port, {:exit_status, status}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      120_000 -> {:error, :bridge_timeout}
    end
  end

  defp resolve_executable(executable) do
    if Path.type(executable) == :absolute and File.regular?(executable) do
      executable
    else
      System.find_executable(executable)
    end
  end

  defp env_entry_to_charlist({key, value}) when is_binary(key) and is_binary(value) do
    {String.to_charlist(key), String.to_charlist(value)}
  end

  defp bridge_command(config) do
    case Keyword.get(config, :bridge_command) do
      [executable | _] = command when is_binary(executable) -> command
      _ -> default_bridge_command()
    end
  end

  defp default_bridge_command do
    node = System.find_executable("node") || System.find_executable("node.exe")

    if is_nil(node) do
      raise "Node.js not found for GitHub Copilot bridge"
    end

    [node, bridge_script_path()]
  end

  defp priv_dir do
    @app
    |> :code.priv_dir()
    |> to_string()
  end

  defp bridge_env(config) do
    config
    |> Keyword.get(:bridge_env, %{})
    |> Enum.into(%{})
    |> Map.merge(%{
      "COPILOT_BRIDGE_MODEL" => to_string(Keyword.get(config, :model, "gpt-4o-mini"))
    })
    |> Enum.into([])
  end

  defp fetch_github_token(config) do
    case Keyword.get(config, :github_token) do
      token when is_binary(token) and token != "" ->
        token

      _ ->
        if Process.whereis(TokenManager) do
          case TokenManager.get_token() do
            {:ok, token} -> token
            _ -> nil
          end
        else
          nil
        end
    end
  end

  defp config, do: Application.get_env(:elixir_claw, ElixirClaw.Providers.Copilot.Client, [])
end
