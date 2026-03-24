defmodule ElixirClaw.MCP.ToolWrapper do
  @moduledoc false

  @behaviour ElixirClaw.Tool

  alias ElixirClaw.MCP.HTTPClient
  alias ElixirClaw.MCP.StdioClient
  alias ElixirClaw.Tools.Registry, as: ToolRegistry

  @default_max_output_bytes 65_536
  @default_timeout_ms 30_000
  @truncation_marker "[OUTPUT TRUNCATED at 64KB]"

  @type client_type :: :http | :stdio

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          schema: map(),
          client_type: client_type(),
          client_pid: pid(),
          server_name: String.t(),
          timeout_ms: non_neg_integer() | nil,
          max_output_bytes: non_neg_integer() | nil
        }

  defstruct [
    :name,
    :description,
    :schema,
    :client_type,
    :client_pid,
    :server_name,
    timeout_ms: nil,
    max_output_bytes: nil
  ]

  defmodule HTTPClientBehaviour do
    @callback list_tools(pid()) :: list() | {:ok, list()} | {:error, term()}
    @callback call_tool(pid(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  end

  defmodule StdioClientBehaviour do
    @callback list_tools(pid()) :: list() | {:ok, list()} | {:error, term()}
    @callback call_tool(pid(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  end

  @impl ElixirClaw.Tool
  def name do
    raise ArgumentError, "ToolWrapper.name/0 is unsupported; use name/1 with a wrapper struct"
  end

  @impl ElixirClaw.Tool
  def description do
    raise ArgumentError,
          "ToolWrapper.description/0 is unsupported; use description/1 with a wrapper struct"
  end

  @impl ElixirClaw.Tool
  def parameters_schema do
    raise ArgumentError,
          "ToolWrapper.parameters_schema/0 is unsupported; use parameters_schema/1 with a wrapper struct"
  end

  @impl ElixirClaw.Tool
  def execute(_params, _context) do
    raise ArgumentError,
          "ToolWrapper.execute/2 is unsupported; use execute/3 with a wrapper struct"
  end

  @impl ElixirClaw.Tool
  def max_output_bytes, do: @default_max_output_bytes

  @impl ElixirClaw.Tool
  def timeout_ms, do: @default_timeout_ms

  @spec name(t()) :: String.t()
  def name(%__MODULE__{server_name: server_name, name: tool_name}) do
    "mcp:" <> server_name <> ":" <> tool_name
  end

  @spec description(t()) :: String.t()
  def description(%__MODULE__{description: description}) when is_binary(description), do: description
  def description(%__MODULE__{}), do: ""

  @spec parameters_schema(t()) :: map()
  def parameters_schema(%__MODULE__{schema: schema}) when is_map(schema), do: schema
  def parameters_schema(%__MODULE__{}), do: %{}

  @spec execute(t(), map(), map()) :: {:ok, String.t()} | {:error, term()}
  def execute(%__MODULE__{} = wrapper, params, _context) when is_map(params) do
    wrapper
    |> client_module()
    |> call_tool(wrapper.client_pid, wrapper.name, params)
    |> normalize_execute_result(max_output_bytes(wrapper))
  end

  @spec max_output_bytes(t()) :: non_neg_integer()
  def max_output_bytes(%__MODULE__{max_output_bytes: value}) when is_integer(value) and value >= 0, do: value
  def max_output_bytes(%__MODULE__{}), do: @default_max_output_bytes

  @spec timeout_ms(t()) :: non_neg_integer()
  def timeout_ms(%__MODULE__{timeout_ms: value}) when is_integer(value) and value >= 0, do: value
  def timeout_ms(%__MODULE__{}), do: @default_timeout_ms

  def register_mcp_tools(server_name, client_pid, client_type) do
    register_mcp_tools(ToolRegistry, server_name, client_pid, client_type)
  end

  def register_mcp_tools(registry, server_name, client_pid, client_type)
      when is_atom(registry) and is_binary(server_name) and is_pid(client_pid) and
             client_type in [:http, :stdio] do
    with {:ok, tools} <- list_tools(client_pid, client_type) do
      wrappers =
        Enum.map(tools, fn tool_spec ->
          %__MODULE__{
            name: fetch_tool_name(tool_spec),
            description: fetch_tool_description(tool_spec),
            schema: fetch_tool_schema(tool_spec),
            client_type: client_type,
            client_pid: client_pid,
            server_name: server_name
          }
        end)

      Enum.each(wrappers, &ToolRegistry.register(registry, &1))
      {:ok, wrappers}
    end
  end

  @spec unregister_mcp_tools(atom(), String.t()) :: :ok
  def unregister_mcp_tools(registry, server_name) when is_atom(registry) and is_binary(server_name) do
    prefix = "mcp:" <> server_name <> ":"

    registry
    |> ToolRegistry.list()
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.each(&ToolRegistry.unregister(registry, &1))

    :ok
  end

  defp list_tools(client_pid, client_type) do
    client_pid
    |> client_module(client_type)
    |> Kernel.apply(:list_tools, [client_pid])
    |> normalize_list_tools_result()
  end

  defp normalize_list_tools_result({:ok, tools}) when is_list(tools), do: {:ok, tools}
  defp normalize_list_tools_result({:error, reason}), do: {:error, reason}
  defp normalize_list_tools_result(tools) when is_list(tools), do: {:ok, tools}
  defp normalize_list_tools_result(other), do: {:error, other}

  defp fetch_tool_name(%{name: name}) when is_binary(name), do: name
  defp fetch_tool_name(%{"name" => name}) when is_binary(name), do: name

  defp fetch_tool_description(%{description: description}) when is_binary(description), do: description
  defp fetch_tool_description(%{"description" => description}) when is_binary(description), do: description
  defp fetch_tool_description(_tool), do: ""

  defp fetch_tool_schema(%{schema: schema}) when is_map(schema), do: schema
  defp fetch_tool_schema(%{"schema" => schema}) when is_map(schema), do: schema
  defp fetch_tool_schema(%{input_schema: schema}) when is_map(schema), do: schema
  defp fetch_tool_schema(%{"inputSchema" => schema}) when is_map(schema), do: schema
  defp fetch_tool_schema(_tool), do: %{}

  defp client_module(%__MODULE__{client_type: client_type}), do: client_module(nil, client_type)

  defp client_module(_client_pid, :http) do
    Application.get_env(:elixir_claw, :mcp_http_client_module, HTTPClient)
  end

  defp client_module(_client_pid, :stdio) do
    Application.get_env(:elixir_claw, :mcp_stdio_client_module, StdioClient)
  end

  defp call_tool(client_module, client_pid, tool_name, params) do
    client_module.call_tool(client_pid, tool_name, params)
  end

  defp normalize_execute_result({:ok, result}, max_output_bytes) when is_binary(result) do
    {:ok, truncate_output(result, max_output_bytes)}
  end

  defp normalize_execute_result({:ok, result}, max_output_bytes) do
    {:ok, truncate_output(to_string(result), max_output_bytes)}
  end

  defp normalize_execute_result({:error, reason}, _max_output_bytes), do: {:error, reason}

  defp truncate_output(output, max_output_bytes) when byte_size(output) > max_output_bytes do
    binary_part(output, 0, max_output_bytes) <> @truncation_marker
  end

  defp truncate_output(output, _max_output_bytes), do: output
end
