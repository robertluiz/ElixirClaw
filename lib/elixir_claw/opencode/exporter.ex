defmodule ElixirClaw.OpenCode.Exporter do
  @moduledoc """
  Exports ElixirClaw sessions to OpenCode via the HTTP API.
  """

  alias ElixirClaw.Repo
  alias ElixirClaw.Session.Manager
  alias ElixirClaw.Types.{Message, Session}

  @default_api_url "http://localhost:3000"
  @default_timeout 5_000
  @max_tool_content_bytes 10_240
  @tool_truncation_suffix "\n[TRUNCATED tool output >10KB]"

  @spec export_session(String.t(), keyword()) ::
          {:ok, %{opencode_session_id: String.t(), messages_exported: non_neg_integer()}}
          | {:error, term()}
  def export_session(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    with {:ok, %Session{} = session} <- Manager.get_session(session_id),
         {:ok, opencode_session_id} <- create_remote_session(session, opts),
         {:ok, messages_exported} <- export_messages(opencode_session_id, session_id, opts) do
      {:ok, %{opencode_session_id: opencode_session_id, messages_exported: messages_exported}}
    end
  end

  @spec push_message(String.t(), Message.t(), keyword()) :: :ok | {:error, term()}
  def push_message(opencode_session_id, %Message{} = message, opts \\ [])
      when is_binary(opencode_session_id) and is_list(opts) do
    with {:ok, request_options} <- base_request_options(opts),
         {:ok, response} <-
           request(
             fn ->
               Req.post(
                 Keyword.merge(request_options,
                   url: session_message_url(opencode_session_id, opts),
                   json: message_payload(message)
                 )
               )
             end,
             timeout(opts)
           ) do
      case response.status do
        status when status in 200..299 -> :ok
        401 -> {:error, :unauthorized}
        status -> {:error, {:http_error, status}}
      end
    else
      {:error, reason} -> {:error, normalize_transport_error(reason, opts)}
    end
  end

  @spec check_connection(keyword()) :: :ok | {:error, term()}
  def check_connection(opts \\ []) when is_list(opts) do
    with {:ok, request_options} <- base_request_options(opts),
         {:ok, response} <-
           request(
             fn -> Req.get(Keyword.merge(request_options, url: health_check_url(opts))) end,
             timeout(opts)
           ) do
      case response.status do
        status when status in 200..299 -> :ok
        401 -> {:error, :unauthorized}
        status -> {:error, {:http_error, status}}
      end
    else
      {:error, reason} -> {:error, normalize_transport_error(reason, opts)}
    end
  end

  defp create_remote_session(%Session{} = session, opts) do
    with {:ok, request_options} <- base_request_options(opts),
         {:ok, response} <-
           request(
             fn ->
               Req.post(
                 Keyword.merge(request_options,
                   url: session_url(opts),
                   json: %{title: session.id, directory: "."}
                 )
               )
             end,
             timeout(opts)
           ),
         :ok <- validate_status(response),
         {:ok, body} <- decode_body(response.body),
         {:ok, id} <- extract_session_id(body) do
      {:ok, id}
    else
      {:error, reason} -> {:error, normalize_transport_error(reason, opts)}
    end
  end

  defp export_messages(opencode_session_id, session_id, opts) do
    messages = list_session_messages(session_id)

    case Enum.reduce_while(messages, {:ok, 0}, fn message, {:ok, count} ->
           case push_message(opencode_session_id, message, opts) do
             :ok -> {:cont, {:ok, count + 1}}
             {:error, reason} -> {:halt, {:error, reason}}
           end
         end) do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_session_messages(session_id) do
    Repo.list_session_messages(session_id)
    |> Enum.map(&to_message/1)
  end

  defp to_message(message) do
    %Message{
      role: message.role,
      content: message.content,
      tool_calls: message.tool_calls,
      tool_call_id: message.tool_call_id,
      token_count: message.token_count,
      timestamp: message.inserted_at
    }
  end

  defp message_payload(%Message{} = message) do
    %{
      role: message.role,
      content: [
        %{
          type: "text",
          text: sanitized_content(message)
        }
      ]
    }
  end

  defp sanitized_content(%Message{role: "tool", content: content}) when is_binary(content) do
    truncate_tool_content(content)
  end

  defp sanitized_content(%Message{content: content}) when is_binary(content), do: content
  defp sanitized_content(%Message{}), do: ""

  defp truncate_tool_content(content) when byte_size(content) > @max_tool_content_bytes do
    keep_bytes = max(@max_tool_content_bytes - byte_size(@tool_truncation_suffix), 0)
    binary_part(content, 0, keep_bytes) <> @tool_truncation_suffix
  end

  defp truncate_tool_content(content), do: content

  defp validate_status(%Req.Response{status: status}) when status in 200..299, do: :ok
  defp validate_status(%Req.Response{status: 401}), do: {:error, :unauthorized}
  defp validate_status(%Req.Response{status: status}), do: {:error, {:http_error, status}}

  defp decode_body(body) when is_map(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_response}
    end
  end

  defp decode_body(_body), do: {:error, :invalid_response}

  defp extract_session_id(%{"id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp extract_session_id(%{id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp extract_session_id(_body), do: {:error, :invalid_response}

  defp base_request_options(opts) do
    with {:ok, api_url} <- api_url(opts) do
      {:ok,
       [
         headers: [
           {"authorization", authorization_header()},
           {"content-type", "application/json"}
         ],
         receive_timeout: timeout(opts),
         connect_options: [timeout: timeout(opts)],
         retry: false
       ]
       |> Keyword.put(:base_url, api_url)}
    end
  end

  defp request(fun, timeout_ms)
       when is_function(fun, 0) and is_integer(timeout_ms) and timeout_ms >= 0 do
    parent = self()
    result_ref = make_ref()

    pid =
      spawn(fn ->
        result =
          try do
            fun.()
          catch
            :exit, reason -> {:error, reason}
          end

        send(parent, {:request_result, result_ref, result})
      end)

    monitor_ref = Process.monitor(pid)

    receive do
      {:request_result, ^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, reason}
    after
      timeout_ms + 1_000 ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  defp api_url(opts) do
    api_url =
      opts
      |> Keyword.get_lazy(:api_url, fn ->
        :elixir_claw
        |> Application.get_env(:opencode, [])
        |> Keyword.get(:api_url, @default_api_url)
      end)
      |> to_string()
      |> String.trim()
      |> String.trim_trailing("/")

    if String.starts_with?(api_url, ["http://", "https://"]) do
      {:ok, api_url}
    else
      {:error, :invalid_api_url}
    end
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout, @default_timeout)

  defp authorization_header do
    "Bearer " <> System.get_env("OPENCODE_CONSOLE_TOKEN", "")
  end

  defp health_check_url(opts), do: session_url(opts) <> "?limit=1"
  defp session_url(opts), do: Keyword.fetch!(base_request_url(opts), :session)

  defp session_message_url(opencode_session_id, opts) do
    Keyword.fetch!(base_request_url(opts), :session) <>
      "/" <> URI.encode(opencode_session_id) <> "/message"
  end

  defp base_request_url(opts) do
    {:ok, api_url} = api_url(opts)
    [session: api_url <> "/session"]
  end

  defp normalize_transport_error(:unauthorized, _opts), do: :unauthorized
  defp normalize_transport_error(:invalid_api_url, _opts), do: :invalid_api_url
  defp normalize_transport_error({:http_error, status}, _opts), do: {:http_error, status}
  defp normalize_transport_error(:invalid_response, _opts), do: :invalid_response

  defp normalize_transport_error(reason, opts) do
    case root_reason(reason) do
      :timeout ->
        timeout_or_connection_refused(opts)

      :connect_timeout ->
        :timeout

      :shutdown ->
        :timeout

      :econnrefused ->
        :connection_refused

      :nxdomain ->
        :connection_refused

      other when other in [:closed, :econnaborted, :ehostunreach, :enetunreach] ->
        :connection_refused

      _other ->
        reason
    end
  end

  defp root_reason(%{reason: reason}), do: root_reason(reason)
  defp root_reason({:shutdown, reason}), do: root_reason(reason)
  defp root_reason({reason, _detail}), do: root_reason(reason)
  defp root_reason(reason), do: reason

  defp timeout_or_connection_refused(opts) do
    case api_url(opts) do
      {:ok, api_url} ->
        case socket_probe(api_url, timeout(opts)) do
          :connection_refused -> :connection_refused
          _ -> :timeout
        end

      {:error, _reason} ->
        :timeout
    end
  end

  defp socket_probe(api_url, timeout_ms) do
    uri = URI.parse(api_url)
    host = String.to_charlist(uri.host || "localhost")
    port = uri.port || default_port(uri.scheme)

    case :gen_tcp.connect(host, port, [:binary, active: false], timeout_ms) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        :ok

      {:error, :econnrefused} ->
        :connection_refused

      {:error, _reason} ->
        :unreachable
    end
  end

  defp default_port("https"), do: 443
  defp default_port(_scheme), do: 80
end
