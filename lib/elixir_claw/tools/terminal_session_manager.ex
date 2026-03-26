defmodule ElixirClaw.Tools.TerminalSessionManager do
  @moduledoc false

  use GenServer

  @registry ElixirClaw.TerminalSessionRegistry
  @supervisor ElixirClaw.TerminalSessionSupervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def start_session(params), do: GenServer.call(__MODULE__, {:start_session, params})

  def send_input(session_id, input),
    do: GenServer.call(__MODULE__, {:send_input, session_id, input})

  def read_output(session_id, opts \\ []),
    do: GenServer.call(__MODULE__, {:read_output, session_id, opts})

  def stop_session(session_id), do: GenServer.call(__MODULE__, {:stop_session, session_id})

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:start_session, params}, _from, state) do
    session_id = "term-" <> Integer.to_string(System.unique_integer([:positive]))

    case DynamicSupervisor.start_child(
           @supervisor,
           {ElixirClaw.Tools.TerminalSession, [session_id: session_id, params: params]}
         ) do
      {:ok, _pid} -> {:reply, {:ok, session_id}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_input, session_id, input}, _from, state) do
    {:reply, call_session(session_id, {:send_input, input}), state}
  end

  def handle_call({:read_output, session_id, opts}, _from, state) do
    {:reply, call_session(session_id, {:read_output, opts}), state}
  end

  def handle_call({:stop_session, session_id}, _from, state) do
    {:reply, stop_session_process(session_id), state}
  end

  defp call_session(session_id, message) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _value}] -> GenServer.call(pid, message, 30_000)
      [] -> {:error, :session_not_found}
    end
  catch
    :exit, {:noproc, _details} -> {:error, :session_not_found}
    :exit, reason -> {:error, reason}
  end

  defp stop_session_process(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _value}] -> DynamicSupervisor.terminate_child(@supervisor, pid)
      [] -> {:error, :session_not_found}
    end
  end
end

defmodule ElixirClaw.Tools.TerminalSession do
  @moduledoc false

  use GenServer

  @max_buffer_bytes 131_072

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    params = Keyword.fetch!(opts, :params)

    GenServer.start_link(__MODULE__, {session_id, params}, name: via_tuple(session_id))
  end

  @impl true
  def init({session_id, params}) do
    with {:ok, cwd} <- ElixirClaw.Tools.TerminalHelpers.validate_cwd(Map.get(params, "cwd")),
         {:ok, spec, port_opts, prompt} <- port_command(params, cwd),
         port <- Port.open(spec, port_opts) do
      if prompt != nil do
        _ = Port.command(port, prompt)
      end

      {:ok,
       %{
         session_id: session_id,
         port: port,
         cwd: cwd,
         output_buffer: "",
         output_offset: 0
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_input, input}, _from, state) when is_binary(input) do
    newline = if String.ends_with?(input, "\n"), do: input, else: input <> "\n"
    result = if Port.command(state.port, newline), do: :ok, else: {:error, :send_failed}
    {:reply, result, state}
  end

  def handle_call({:read_output, opts}, _from, state) do
    clear? = Keyword.get(opts, :clear, false)
    output = state.output_buffer

    next_state =
      if clear?,
        do: %{state | output_buffer: "", output_offset: state.output_offset + byte_size(output)},
        else: state

    {:reply, {:ok, output}, next_state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, append_output(state, normalize_port_data(data))}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:port_exit, status},
     append_output(state, "\n[process exited with status #{status}]\n")}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) do
    if Port.info(port) != nil do
      Port.close(port)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp append_output(state, chunk) do
    buffer = state.output_buffer <> chunk

    if byte_size(buffer) <= @max_buffer_bytes do
      %{state | output_buffer: buffer}
    else
      overflow = byte_size(buffer) - @max_buffer_bytes

      %{
        state
        | output_buffer: binary_part(buffer, overflow, @max_buffer_bytes),
          output_offset: state.output_offset + overflow
      }
    end
  end

  defp normalize_port_data({:eol, line}), do: line <> "\n"
  defp normalize_port_data({:noeol, line}), do: line
  defp normalize_port_data(data) when is_binary(data), do: data

  defp port_command(params, cwd) do
    prompt = Map.get(params, "prompt")

    case :os.type() do
      {:win32, _} ->
        shell = System.get_env("COMSPEC") || "cmd"

        {:ok, {:spawn_executable, shell},
         build_port_options(
           [
             :binary,
             :exit_status,
             :stderr_to_stdout,
             :hide,
             :use_stdio,
             {:line, 65_536},
             args: ["/q"]
           ],
           cwd
         ), prompt}

      _other ->
        {:ok, {:spawn_executable, "/bin/sh"},
         build_port_options(
           [
             :binary,
             :exit_status,
             :stderr_to_stdout,
             :use_stdio,
             {:line, 65_536},
             args: ["-i"]
           ],
           cwd
         ), prompt}
    end
  end

  defp build_port_options(options, nil), do: options
  defp build_port_options(options, cwd), do: Keyword.put(options, :cd, cwd)

  defp via_tuple(session_id),
    do: {:via, Registry, {ElixirClaw.TerminalSessionRegistry, session_id}}
end
