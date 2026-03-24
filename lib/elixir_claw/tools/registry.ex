defmodule ElixirClaw.Tools.Registry do
  @moduledoc false

  use GenServer

  @default_max_output_bytes 65_536
  @default_timeout_ms 30_000
  @truncation_marker "[OUTPUT TRUNCATED at 64KB]"

  @type state :: %{tools: %{optional(String.t()) => module()}}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def register(tool_module), do: register(__MODULE__, tool_module)

  def register(server, tool_module) when is_atom(server) and is_atom(tool_module) do
    GenServer.call(server, {:register, tool_module})
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
    with {:ok, tool_module} <- get(name, server),
         :ok <- validate_params(tool_module, params) do
      timeout_ms = timeout_ms(tool_module)
      max_output_bytes = max_output_bytes(tool_module)

      task =
        Task.Supervisor.async_nolink(ElixirClaw.ToolSupervisor, fn ->
          apply(tool_module, :execute, [params, context])
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
    |> Enum.map(fn {:ok, tool_module} ->
      %{
        type: "function",
        function: %{
          name: apply(tool_module, :name, []),
          description: apply(tool_module, :description, []),
          parameters: apply(tool_module, :parameters_schema, [])
        }
      }
    end)
  end

  @impl true
  def init(:ok) do
    {:ok, %{tools: %{}}}
  end

  @impl true
  def handle_call({:register, tool_module}, _from, state) do
    tool_name = apply(tool_module, :name, [])
    {:reply, :ok, put_in(state, [:tools, tool_name], tool_module)}
  end

  def handle_call(:list, _from, state) do
    names = state.tools |> Map.keys() |> Enum.sort()
    {:reply, names, state}
  end

  def handle_call({:get, name}, _from, state) do
    case Map.fetch(state.tools, name) do
      {:ok, tool_module} -> {:reply, {:ok, tool_module}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  defp validate_params(tool_module, params) do
    required_keys =
      tool_module
      |> apply(:parameters_schema, [])
      |> Map.get("required", [])

    if Enum.all?(required_keys, &Map.has_key?(params, &1)) do
      :ok
    else
      {:error, :invalid_params}
    end
  end

  defp timeout_ms(tool_module) do
    if function_exported?(tool_module, :timeout_ms, 0) do
      apply(tool_module, :timeout_ms, [])
    else
      @default_timeout_ms
    end
  end

  defp max_output_bytes(tool_module) do
    if function_exported?(tool_module, :max_output_bytes, 0) do
      apply(tool_module, :max_output_bytes, [])
    else
      @default_max_output_bytes
    end
  end

  defp truncate_output(output, max_output_bytes) when byte_size(output) > max_output_bytes do
    binary_part(output, 0, max_output_bytes) <> @truncation_marker
  end

  defp truncate_output(output, _max_output_bytes), do: output
end
