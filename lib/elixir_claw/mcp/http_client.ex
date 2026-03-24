defmodule ElixirClaw.MCP.HTTPClient do
  @moduledoc false

  use GenServer

  alias Hermes.Client.Base, as: HermesClient
  alias Hermes.Client.Supervisor, as: HermesSupervisor
  alias Hermes.MCP.Response, as: HermesResponse

  @default_timeout_ms 30_000
  @default_poll_interval_ms 20
  @max_output_bytes 65_536
  @truncation_marker "[OUTPUT TRUNCATED at 64KB]"
  @localhost_hosts ["localhost", "127.0.0.1", "::1"]

  @type tool_info :: %{name: String.t(), description: String.t(), schema: map()}
  @type state :: %{
          supervisor_pid: pid(),
          client_name: GenServer.name(),
          transport_name: GenServer.name(),
          timeout_ms: pos_integer(),
          tools_cache: [tool_info()] | nil
        }

  def connect(opts), do: GenServer.start(__MODULE__, opts)

  def list_tools(client_pid) when is_pid(client_pid) do
    GenServer.call(client_pid, :list_tools, call_timeout(client_pid))
  catch
    :exit, _ -> []
  end

  def call_tool(client_pid, name, params)
      when is_pid(client_pid) and is_binary(name) and is_map(params) do
    GenServer.call(client_pid, {:call_tool, name, params}, call_timeout(client_pid))
  catch
    :exit, reason -> {:error, reason}
  end

  def disconnect(client_pid) when is_pid(client_pid) do
    GenServer.stop(client_pid, :normal)
  catch
    :exit, _ -> :ok
  else
    _ -> :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, url} <- fetch_url(opts),
         :ok <- validate_url(url),
         timeout_ms <- Keyword.get(opts, :timeout, @default_timeout_ms),
         connect_timeout_ms <- Keyword.get(opts, :connect_timeout, max(timeout_ms, 5_000)),
         {:ok, supervisor_pid, client_name, transport_name} <- start_hermes_client(url),
         :ok <- wait_until_ready(client_name, connect_timeout_ms) do
      {:ok,
       %{
         supervisor_pid: supervisor_pid,
         client_name: client_name,
         transport_name: transport_name,
         timeout_ms: timeout_ms,
         tools_cache: nil
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:EXIT, supervisor_pid, _reason}, %{supervisor_pid: supervisor_pid} = state) do
    {:noreply, %{state | supervisor_pid: nil, tools_cache: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:list_tools, _from, %{tools_cache: tools} = state) when is_list(tools) do
    {:reply, tools, state}
  end

  def handle_call(:list_tools, _from, state) do
    case run_with_timeout(state.timeout_ms, fn ->
           HermesClient.list_tools(state.client_name, timeout: inner_timeout(state.timeout_ms))
         end) do
      {:ok, {:ok, response}} ->
        tools =
          response
          |> HermesResponse.unwrap()
          |> Map.get("tools", [])
          |> Enum.map(&normalize_tool/1)

        {:reply, tools, %{state | tools_cache: tools}}

      _ ->
        {:reply, [], state}
    end
  end

  def handle_call({:call_tool, name, params}, _from, state) do
    result =
      state.timeout_ms
      |> run_with_timeout(fn ->
        HermesClient.call_tool(state.client_name, name, params,
          timeout: inner_timeout(state.timeout_ms)
        )
      end)
      |> normalize_tool_result()

    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, %{supervisor_pid: supervisor_pid, client_name: client_name})
      when is_pid(supervisor_pid) do
    _ = HermesClient.close(client_name)
    _ = Supervisor.stop(supervisor_pid)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp fetch_url(opts) do
    case Keyword.fetch(opts, :url) do
      {:ok, url} when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, :invalid_url}
    end
  end

  defp validate_url(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] -> {:error, :invalid_url}
      is_nil(uri.host) -> {:error, :invalid_url}
      uri.scheme == "http" and uri.host not in @localhost_hosts -> {:error, :insecure_transport}
      true -> :ok
    end
  end

  defp start_hermes_client(url) do
    identifier = System.unique_integer([:positive])
    client_name = {:global, {__MODULE__, identifier, :client}}
    transport_name = {:global, {__MODULE__, identifier, :transport}}

    {base_url, mcp_path} = split_url(url)

    opts = [
      client_name: client_name,
      transport_name: transport_name,
      transport: {:streamable_http, [base_url: base_url, mcp_path: mcp_path]},
      client_info: %{"name" => "ElixirClaw", "version" => "0.1.0"},
      capabilities: %{},
      protocol_version: "2025-03-26"
    ]

    case HermesSupervisor.start_link(__MODULE__.HermesClient, opts) do
      {:ok, supervisor_pid} -> {:ok, supervisor_pid, client_name, transport_name}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wait_until_ready(client_name, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_ready(client_name, deadline)
  end

  defp do_wait_until_ready(client_name, deadline) do
    case HermesClient.get_server_info(client_name, timeout: 50) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(@default_poll_interval_ms)
          do_wait_until_ready(client_name, deadline)
        end

      _info ->
        :ok
    end
  catch
    :exit, _ ->
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :timeout}
      else
        Process.sleep(@default_poll_interval_ms)
        do_wait_until_ready(client_name, deadline)
      end
  end

  defp split_url(url) do
    uri = URI.parse(url)
    path = uri.path || "/"

    mcp_path =
      case uri.query do
        nil -> path
        query -> path <> "?" <> query
      end

    base_url = %URI{uri | path: nil, query: nil, fragment: nil} |> URI.to_string()
    {base_url, mcp_path}
  end

  defp normalize_tool(%{"name" => name} = tool) do
    %{
      name: name,
      description: Map.get(tool, "description", ""),
      schema: Map.get(tool, "inputSchema", %{})
    }
  end

  defp normalize_tool_result({:ok, {:ok, response}}) do
    result = HermesResponse.unwrap(response)

    if Map.get(result, "isError", false) do
      {:error, extract_error(result)}
    else
      {:ok, result |> extract_content_text() |> truncate_output()}
    end
  end

  defp normalize_tool_result({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_tool_result({:error, :timeout}), do: {:error, :timeout}
  defp normalize_tool_result({:error, reason}), do: {:error, reason}

  defp extract_error(%{"content" => [%{"text" => text} | _]}), do: text
  defp extract_error(%{"message" => message}), do: message
  defp extract_error(other), do: other

  defp extract_content_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(&content_item_to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp extract_content_text(%{"structuredContent" => content}), do: Jason.encode!(content)
  defp extract_content_text(other), do: Jason.encode!(other)

  defp content_item_to_string(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp content_item_to_string(item), do: Jason.encode!(item)

  defp truncate_output(output) when byte_size(output) > @max_output_bytes do
    binary_part(output, 0, @max_output_bytes) <> @truncation_marker
  end

  defp truncate_output(output), do: output

  defp inner_timeout(timeout_ms), do: timeout_ms + 1_000

  defp run_with_timeout(timeout_ms, fun) do
    task = Task.Supervisor.async_nolink(ElixirClaw.ToolSupervisor, fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      {:exit, :timeout} -> {:error, :timeout}
      {:exit, {:timeout, _}} -> {:error, :timeout}
      {:exit, :shutdown} -> {:error, :timeout}
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  defp call_timeout(client_pid) do
    case Process.alive?(client_pid) do
      true -> 31_000
      false -> 5_000
    end
  end

  defmodule HermesClient do
  end
end
