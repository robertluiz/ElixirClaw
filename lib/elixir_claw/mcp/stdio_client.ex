defmodule ElixirClaw.MCP.StdioClient do
  @moduledoc """
  Port-owned GenServer for MCP stdio transport.

  Security note: `:command` must come from trusted configuration only.
  This client resolves executables and uses `{:spawn_executable, path}` to avoid
  shell injection risks from `{:spawn, shell_command}`.
  """

  use GenServer

  @default_timeout_ms 30_000
  @max_output_bytes 65_536
  @truncation_marker "[OUTPUT TRUNCATED at 64KB]"

  @type tool_spec :: %{name: String.t(), description: String.t() | nil, schema: map()}
  @type state :: %{
          port: port() | reference(),
          send_fn: (port() | reference(), iodata() -> term()),
          port_close_fn: (port() | reference() -> term()),
          pending_requests: %{optional(integer()) => {GenServer.from(), reference(), atom()}},
          next_id: non_neg_integer(),
          timeout_ms: non_neg_integer()
        }

  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name)

    case build_port_command(opts) do
      {:ok, spec, port_options} ->
        start_options = if name, do: [name: name], else: []
        GenServer.start_link(__MODULE__, {opts, spec, port_options}, start_options)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_tools(server) do
    GenServer.call(server, :list_tools, :infinity)
  end

  def call_tool(server, name, params) when is_binary(name) and is_map(params) do
    GenServer.call(server, {:call_tool, name, params}, :infinity)
  end

  def stop(server) do
    GenServer.call(server, :stop)
  end

  @impl true
  def init({opts, spec, port_options}) do
    port_open_fn = Keyword.get(opts, :port_open_fn, &default_port_open/2)
    send_fn = Keyword.get(opts, :send_fn, &default_send/2)
    port_close_fn = Keyword.get(opts, :port_close_fn, &default_port_close/1)

    case port_open_fn.(spec, port_options) do
      {:ok, port} ->
        {:ok,
         %{
           port: port,
           send_fn: send_fn,
           port_close_fn: port_close_fn,
           pending_requests: %{},
           next_id: 1,
           timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
         }}

      {:error, reason} ->
        {:stop, reason}

      port ->
        {:ok,
         %{
           port: port,
           send_fn: send_fn,
           port_close_fn: port_close_fn,
           pending_requests: %{},
           next_id: 1,
           timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
         }}
    end
  end

  @impl true
  def handle_call(:list_tools, from, state) do
    send_request("tools/list", %{}, from, :list_tools, state)
  end

  def handle_call({:call_tool, name, params}, from, state) do
    send_request("tools/call", %{"name" => name, "arguments" => params}, from, :call_tool, state)
  end

  def handle_call(:stop, _from, state) do
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    {:noreply, maybe_handle_jsonrpc_line(line, state)}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
    replied_state = fail_pending_requests(state, :process_exited)
    {:stop, :process_exited, replied_state}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending_requests, id) do
      {{from, timer_ref, _request_type}, pending_requests} ->
        _ = Process.cancel_timer(timer_ref)
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending_requests: pending_requests}}

      {nil, _pending_requests} ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_port(state)
    :ok
  end

  defp send_request(method, params, from, request_type, state) do
    id = state.next_id
    payload = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}) <> "\n"

    case state.send_fn.(state.port, payload) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      _ ->
        timer_ref = Process.send_after(self(), {:request_timeout, id}, state.timeout_ms)

        next_state = %{
          state
          | next_id: id + 1,
            pending_requests: Map.put(state.pending_requests, id, {from, timer_ref, request_type})
        }

        {:noreply, next_state}
    end
  end

  defp maybe_handle_jsonrpc_line(line, state) do
    with {:ok, message} <- Jason.decode(line),
         id when is_integer(id) <- message["id"],
         {{from, timer_ref, request_type}, pending_requests} <- Map.pop(state.pending_requests, id) do
      _ = Process.cancel_timer(timer_ref)
      GenServer.reply(from, decode_response(message, request_type))
      %{state | pending_requests: pending_requests}
    else
      _ -> state
    end
  end

  defp decode_response(%{"error" => error}, _request_type) when is_map(error) do
    {:error, error_reason(error)}
  end

  defp decode_response(%{"result" => result}, :list_tools) when is_map(result) do
    tools =
      result
      |> Map.get("tools", [])
      |> Enum.map(fn tool ->
        %{
          name: Map.get(tool, "name"),
          description: Map.get(tool, "description"),
          schema: Map.get(tool, "inputSchema", %{})
        }
      end)

    {:ok, tools}
  end

  defp decode_response(%{"result" => result}, :call_tool) when is_map(result) do
    {:ok, result |> extract_tool_result() |> truncate_output()}
  end

  defp decode_response(_message, _request_type), do: {:error, :invalid_response}

  defp extract_tool_result(%{"content" => content}) when is_list(content) do
    text =
      content
      |> Enum.flat_map(fn
        %{"type" => "text", "text" => text} when is_binary(text) -> [text]
        _ -> []
      end)
      |> Enum.join("\n")

    if text == "" do
      Jason.encode!(%{"content" => content})
    else
      text
    end
  end

  defp extract_tool_result(result) when is_map(result), do: Jason.encode!(result)
  defp extract_tool_result(result), do: to_string(result)

  defp error_reason(error) do
    cond do
      is_binary(error["message"]) -> error["message"]
      is_integer(error["code"]) -> error["code"]
      true -> :request_failed
    end
  end

  defp fail_pending_requests(state, reason) do
    Enum.each(state.pending_requests, fn {_id, {from, timer_ref, _request_type}} ->
      _ = Process.cancel_timer(timer_ref)
      GenServer.reply(from, {:error, reason})
    end)

    %{state | pending_requests: %{}}
  end

  defp close_port(%{port: port, port_close_fn: port_close_fn}) when not is_nil(port) do
    _ = port_close_fn.(port)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp close_port(_state), do: :ok

  defp truncate_output(output) when byte_size(output) > @max_output_bytes do
    binary_part(output, 0, @max_output_bytes) <> @truncation_marker
  end

  defp truncate_output(output), do: output

  defp build_port_command(opts) do
    with {:ok, command} <- fetch_command(opts),
         {:ok, executable, args} <- resolve_command(command) do
      {:ok, {:spawn_executable, executable}, build_port_options(args, opts)}
    end
  end

  defp fetch_command(opts) do
    case Keyword.get(opts, :command) do
      [executable | _] = command when is_binary(executable) -> {:ok, command}
      _ -> {:error, :command_not_found}
    end
  end

  defp resolve_command([executable | args]) do
    cond do
      shell_script?(executable) -> resolve_shell_script_command(executable, args)
      true -> resolve_direct_command(executable, args)
    end
  end

  defp resolve_direct_command(executable, args) do
    case resolve_executable(executable) do
      nil -> {:error, :command_not_found}
      resolved -> {:ok, resolved, args}
    end
  end

  defp resolve_shell_script_command(executable, args) do
    if File.regular?(executable) do
      case resolve_executable(System.get_env("COMSPEC") || "cmd") do
        nil -> {:error, :command_not_found}
        cmd_path -> {:ok, cmd_path, ["/c", executable | args]}
      end
    else
      {:error, :command_not_found}
    end
  end

  defp resolve_executable(executable) do
    cond do
      Path.type(executable) == :absolute and File.regular?(executable) -> executable
      true -> System.find_executable(executable)
    end
  end

  defp shell_script?(path) do
    path
    |> Path.extname()
    |> String.downcase()
    |> Kernel.in([".cmd", ".bat"])
  end

  defp build_port_options(args, opts) do
    base_options = [:binary, :exit_status, {:line, 65_536}, args: args]

    base_options
    |> maybe_put_cd(Keyword.get(opts, :cwd))
    |> maybe_put_env(Keyword.get(opts, :env, []))
  end

  defp maybe_put_cd(options, nil), do: options
  defp maybe_put_cd(options, cwd), do: Keyword.put(options, :cd, cwd)

  defp maybe_put_env(options, env) when is_list(env) and env != [] do
    Keyword.put(options, :env, Enum.map(env, &env_entry_to_charlist/1))
  end

  defp maybe_put_env(options, _env), do: options

  defp env_entry_to_charlist({key, value}) when is_binary(key) and is_binary(value) do
    {String.to_charlist(key), String.to_charlist(value)}
  end

  defp default_port_open(spec, options), do: {:ok, Port.open(spec, options)}
  defp default_send(port, payload), do: Port.command(port, payload)
  defp default_port_close(port), do: Port.close(port)
end
