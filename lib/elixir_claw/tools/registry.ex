defmodule ElixirClaw.Tools.Registry do
  @moduledoc false

  use GenServer

  alias ElixirClaw.MCP.ToolWrapper

  @default_max_output_bytes 65_536
  @default_timeout_ms 30_000
  @truncation_marker "[OUTPUT TRUNCATED at 64KB]"

  @type tool_entry :: module() | ToolWrapper.t()
  @type state :: %{tools: %{optional(String.t()) => tool_entry()}}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def register(tool), do: register(__MODULE__, tool)

  def register(server, tool) when is_atom(server) and (is_atom(tool) or is_struct(tool, ToolWrapper)) do
    GenServer.call(server, {:register, tool})
  end

  def unregister(name), do: unregister(__MODULE__, name)

  def unregister(server, name) when is_atom(server) and is_binary(name) do
    GenServer.call(server, {:unregister, name})
  end

  def list, do: list(__MODULE__)

  def list(server) when is_atom(server) do
    GenServer.call(server, :list)
  end

  def get(name), do: get(name, __MODULE__)

  def get(name, server) when is_binary(name) and is_atom(server) do
    GenServer.call(server, {:get, name})
  end

  def execute(name, params, context), do: execute(name, params, context, __MODULE__)

  def execute(name, params, context, server)
      when is_binary(name) and is_map(params) and is_map(context) and is_atom(server) do
    with {:ok, tool} <- get(name, server),
         :ok <- validate_params(tool, params) do
      timeout_ms = timeout_ms(tool)
      max_output_bytes = max_output_bytes(tool)

      task =
        Task.Supervisor.async_nolink(ElixirClaw.ToolSupervisor, fn ->
          execute_tool(tool, params, context)
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, result}} when is_binary(result) ->
          {:ok, truncate_output(result, max_output_bytes)}

        {:ok, {:ok, result}} ->
          {:ok, truncate_output(to_string(result), max_output_bytes)}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:exit, :timeout} ->
          {:error, :timeout}

        {:exit, reason} ->
          {:error, reason}

        nil ->
          {:error, :timeout}
      end
    end
  end

  def to_provider_format, do: to_provider_format(__MODULE__)

  def to_provider_format(server) when is_atom(server) do
    server
    |> list()
    |> Enum.map(&get(&1, server))
    |> Enum.map(fn {:ok, tool} ->
      %{
        type: "function",
        function: %{
          name: tool_name(tool),
          description: tool_description(tool),
          parameters: parameters_schema(tool)
        }
      }
    end)
  end

  @impl true
  def init(:ok) do
    {:ok, %{tools: %{}}}
  end

  @impl true
  def handle_call({:register, tool}, _from, state) do
    {:reply, :ok, put_in(state, [:tools, tool_name(tool)], tool)}
  end

  def handle_call({:unregister, name}, _from, state) do
    {:reply, :ok, update_in(state, [:tools], &Map.delete(&1, name))}
  end

  def handle_call(:list, _from, state) do
    names = state.tools |> Map.keys() |> Enum.sort()
    {:reply, names, state}
  end

  def handle_call({:get, name}, _from, state) do
    case Map.fetch(state.tools, name) do
      {:ok, tool} -> {:reply, {:ok, tool}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  defp validate_params(tool, params) do
    required_keys =
      tool
      |> parameters_schema()
      |> Map.get("required", [])

    if Enum.all?(required_keys, &Map.has_key?(params, &1)) do
      :ok
    else
      {:error, :invalid_params}
    end
  end

  defp timeout_ms(%ToolWrapper{} = tool), do: ToolWrapper.timeout_ms(tool)

  defp timeout_ms(tool_module) do
    if function_exported?(tool_module, :timeout_ms, 0) do
      apply(tool_module, :timeout_ms, [])
    else
      @default_timeout_ms
    end
  end

  defp max_output_bytes(%ToolWrapper{} = tool), do: ToolWrapper.max_output_bytes(tool)

  defp max_output_bytes(tool_module) do
    if function_exported?(tool_module, :max_output_bytes, 0) do
      apply(tool_module, :max_output_bytes, [])
    else
      @default_max_output_bytes
    end
  end

  defp tool_name(%ToolWrapper{} = tool), do: ToolWrapper.name(tool)
  defp tool_name(tool_module), do: apply(tool_module, :name, [])

  defp tool_description(%ToolWrapper{} = tool), do: ToolWrapper.description(tool)
  defp tool_description(tool_module), do: apply(tool_module, :description, [])

  defp parameters_schema(%ToolWrapper{} = tool), do: ToolWrapper.parameters_schema(tool)
  defp parameters_schema(tool_module), do: apply(tool_module, :parameters_schema, [])

  defp execute_tool(%ToolWrapper{} = tool, params, context), do: ToolWrapper.execute(tool, params, context)
  defp execute_tool(tool_module, params, context), do: apply(tool_module, :execute, [params, context])

  defp truncate_output(output, max_output_bytes) when byte_size(output) > max_output_bytes do
    binary_part(output, 0, max_output_bytes) <> @truncation_marker
  end

  defp truncate_output(output, _max_output_bytes), do: output
end
