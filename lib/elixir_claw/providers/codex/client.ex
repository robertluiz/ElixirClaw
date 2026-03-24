defmodule ElixirClaw.Providers.Codex.Client do
  @moduledoc """
  Codex provider implementation for the Responses API.
  """

  @behaviour ElixirClaw.Provider

  alias ElixirClaw.Providers.Codex.TokenManager
  alias ElixirClaw.Types.{ProviderResponse, TokenUsage, ToolCall}

  @default_base_url "https://chatgpt.com/backend-api/codex/responses"
  @default_models ["codex-mini"]

  @impl true
  def name, do: "codex"

  @impl true
  def models do
    config()
    |> Keyword.get(:models, @default_models)
    |> List.wrap()
  end

  @impl true
  def count_tokens(text, _model) when is_binary(text) do
    {:ok, div(String.length(text) + 3, 4)}
  end

  @impl true
  def chat(messages, opts \\ []) when is_list(messages) and is_list(opts) do
    with {:ok, request_opts} <- request_options(messages, opts, false),
         {:ok, response} <- Req.post(request_opts),
         :ok <- validate_chat_response(response),
         {:ok, body} <- decode_body(response.body),
         {:ok, parsed} <- parse_chat_response(body) do
      {:ok, parsed}
    else
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def stream(messages, opts \\ []) when is_list(messages) and is_list(opts) do
    with {:ok, request_opts} <- request_options(messages, opts, true),
         {:ok, response} <- Req.post(request_opts),
         :ok <- validate_stream_response(response) do
      {:ok, build_stream(response.body)}
    else
      {:error, _reason} = error -> error
    end
  end

  defp request_options(messages, opts, stream?) do
    with {:ok, access_token} <- fetch_access_token(),
         {:ok, account_id} <- fetch_account_id() do
      request_opts = [
        url: responses_url(),
        auth: {:bearer, access_token},
        headers: request_headers(account_id, stream?),
        json: request_body(messages, opts, stream?)
      ]

      {:ok, maybe_put_into(request_opts, stream?)}
    end
  end

  defp request_headers(account_id, stream?) do
    []
    |> maybe_prepend(stream?, {"accept", "text/event-stream"})
    |> Kernel.++([
      {"chatgpt-account-id", account_id},
      {"content-type", "application/json"}
    ])
  end

  defp request_body(messages, opts, stream?) do
    {instructions, input_items} = format_messages(messages)

    %{
      "model" => Keyword.get(opts, :model, List.first(models())),
      "instructions" => instructions,
      "input" => input_items,
      "stream" => stream?
    }
    |> maybe_put("tools", format_tools(Keyword.get(opts, :tools)))
    |> maybe_put("previous_response_id", Keyword.get(opts, :previous_response_id))
  end

  defp format_messages(messages) do
    {system_messages, conversation_messages} =
      Enum.split_with(messages, fn message -> message_role(message) == "system" end)

    instructions =
      system_messages
      |> Enum.map(&message_content_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    input_items = Enum.flat_map(conversation_messages, &format_input_message/1)

    {instructions, input_items}
  end

  defp format_input_message(message) do
    case message_role(message) do
      "user" ->
        [
          %{
            "role" => "user",
            "content" => format_user_content(message_content(message))
          }
        ]

      "assistant" ->
        format_assistant_items(message)

      "tool" ->
        format_tool_output(message)

      role when is_binary(role) ->
        [
          %{
            "role" => role,
            "content" => [%{"type" => "input_text", "text" => message_content_text(message)}]
          }
        ]

      _other ->
        []
    end
  end

  defp format_user_content(content) when is_binary(content) do
    [%{"type" => "input_text", "text" => content}]
  end

  defp format_user_content(content) when is_list(content) do
    converted =
      Enum.flat_map(content, fn
        %{"type" => "text", "text" => text} when is_binary(text) ->
          [%{"type" => "input_text", "text" => text}]

        %{type: "text", text: text} when is_binary(text) ->
          [%{"type" => "input_text", "text" => text}]

        %{"type" => "image_url", "image_url" => %{"url" => url}} when is_binary(url) ->
          [%{"type" => "input_image", "image_url" => url, "detail" => "auto"}]

        %{type: "image_url", image_url: %{url: url}} when is_binary(url) ->
          [%{"type" => "input_image", "image_url" => url, "detail" => "auto"}]

        _item ->
          []
      end)

    case converted do
      [] -> [%{"type" => "input_text", "text" => ""}]
      items -> items
    end
  end

  defp format_user_content(_content), do: [%{"type" => "input_text", "text" => ""}]

  defp format_assistant_items(message) do
    text_item =
      case assistant_output_content(message_content(message)) do
        [] ->
          []

        content ->
          [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => content,
              "status" => "completed"
            }
          ]
      end

    text_item ++ format_assistant_tool_calls(message_tool_calls(message))
  end

  defp assistant_output_content(content) when is_binary(content) and content != "" do
    [%{"type" => "output_text", "text" => content}]
  end

  defp assistant_output_content(content) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        [%{"type" => "output_text", "text" => text}]

      %{type: "text", text: text} when is_binary(text) ->
        [%{"type" => "output_text", "text" => text}]

      _item ->
        []
    end)
  end

  defp assistant_output_content(_content), do: []

  defp format_assistant_tool_calls(nil), do: []
  defp format_assistant_tool_calls([]), do: []

  defp format_assistant_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tool_call ->
      {call_id, item_id} = split_tool_call_id(tool_call_id(tool_call))

      %{
        "type" => "function_call",
        "id" => item_id || tool_call_id(tool_call),
        "call_id" => call_id,
        "name" => tool_call_name(tool_call),
        "arguments" => Jason.encode!(tool_call_arguments(tool_call))
      }
    end)
  end

  defp format_tool_output(message) do
    case message_tool_call_id(message) do
      nil ->
        []

      tool_call_id ->
        {call_id, _item_id} = split_tool_call_id(tool_call_id)

        [
          %{
            "type" => "function_call_output",
            "call_id" => call_id,
            "output" => message_content_text(message)
          }
        ]
    end
  end

  defp format_tools(nil), do: nil

  defp format_tools(tools) when is_list(tools) do
    Enum.flat_map(tools, fn tool ->
      case format_tool(tool) do
        nil -> []
        formatted -> [formatted]
      end
    end)
  end

  defp format_tool(%{type: "function", function: function}), do: format_function_tool(function)

  defp format_tool(%{"type" => "function", "function" => function}),
    do: format_function_tool(function)

  defp format_tool(tool) when is_map(tool), do: format_function_tool(tool)
  defp format_tool(_tool), do: nil

  defp format_function_tool(function) when is_map(function) do
    name = Map.get(function, :name) || Map.get(function, "name")

    if is_binary(name) and name != "" do
      %{
        "type" => "function",
        "name" => name,
        "description" =>
          Map.get(function, :description) || Map.get(function, "description") || "",
        "parameters" => Map.get(function, :parameters) || Map.get(function, "parameters") || %{}
      }
    end
  end

  defp validate_stream_response(%Req.Response{status: status, body: body})
       when status in 200..299 do
    if Enumerable.impl_for(body), do: :ok, else: {:error, :stream_error}
  end

  defp validate_stream_response(%Req.Response{} = response), do: sanitize_http_error(response)

  defp validate_chat_response(%Req.Response{status: status}) when status in 200..299, do: :ok
  defp validate_chat_response(%Req.Response{} = response), do: sanitize_http_error(response)

  defp build_stream(async_body) do
    initial_state = %{buffer: "", pending_tool_calls: [], tool_call_buffers: %{}}
    Stream.transform(async_body, initial_state, &parse_sse_chunk/2)
  end

  defp parse_sse_chunk(chunk, state) do
    {events, rest} = split_events(state.buffer <> chunk)
    state = %{state | buffer: rest}

    Enum.reduce(events, {[], state}, fn event, {chunks, current_state} ->
      {new_chunks, next_state} = parse_event(event, current_state)
      {chunks ++ new_chunks, next_state}
    end)
  end

  defp split_events(buffer) do
    normalized = String.replace(buffer, "\r\n", "\n")
    parts = String.split(normalized, "\n\n")

    case parts do
      [] -> {[], ""}
      [_single] -> {[], normalized}
      _many -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  defp parse_event(event, state) do
    parsed =
      event
      |> String.split("\n")
      |> Enum.reduce(%{event: nil, data: []}, fn
        "event: " <> type, acc -> %{acc | event: type}
        "data: " <> data, acc -> %{acc | data: [data | acc.data]}
        _line, acc -> acc
      end)

    with event_type when is_binary(event_type) <- parsed.event,
         payload when is_binary(payload) <- parsed.data |> Enum.reverse() |> Enum.join("\n"),
         {:ok, decoded} <- Jason.decode(payload) do
      handle_stream_event(event_type, decoded, state)
    else
      _ -> {[], state}
    end
  end

  defp handle_stream_event("response.created", _payload, state), do: {[], state}

  defp handle_stream_event("response.output_item.added", %{"item" => item}, state) do
    case Map.get(item, "type") do
      "function_call" ->
        call_id = Map.get(item, "call_id")

        next_state =
          if is_binary(call_id) and call_id != "" do
            put_in(state, [:tool_call_buffers, call_id], %{
              id: Map.get(item, "id"),
              name: Map.get(item, "name"),
              arguments: Map.get(item, "arguments") || ""
            })
          else
            state
          end

        {[], next_state}

      _other ->
        {[], state}
    end
  end

  defp handle_stream_event("response.content_part.delta", payload, state) do
    case delta_text(payload) do
      "" -> {[], state}
      delta -> {[%{delta: delta, finish_reason: nil, tool_calls: [], token_usage: nil}], state}
    end
  end

  defp handle_stream_event("response.output_text.delta", payload, state) do
    case delta_text(payload) do
      "" -> {[], state}
      delta -> {[%{delta: delta, finish_reason: nil, tool_calls: [], token_usage: nil}], state}
    end
  end

  defp handle_stream_event("response.function_call_arguments.delta", payload, state) do
    case Map.get(payload, "call_id") do
      call_id when is_binary(call_id) ->
        next_state =
          update_in(state, [:tool_call_buffers, call_id], fn
            nil ->
              %{id: nil, name: nil, arguments: Map.get(payload, "delta") || ""}

            buffer ->
              Map.update(
                buffer,
                :arguments,
                Map.get(payload, "delta") || "",
                &(&1 <> (Map.get(payload, "delta") || ""))
              )
          end)

        {[], next_state}

      _other ->
        {[], state}
    end
  end

  defp handle_stream_event("response.function_call_arguments.done", payload, state) do
    case Map.get(payload, "call_id") do
      call_id when is_binary(call_id) ->
        next_state =
          update_in(state, [:tool_call_buffers, call_id], fn
            nil -> %{id: nil, name: nil, arguments: Map.get(payload, "arguments") || ""}
            buffer -> Map.put(buffer, :arguments, Map.get(payload, "arguments") || "")
          end)

        {[], next_state}

      _other ->
        {[], state}
    end
  end

  defp handle_stream_event("response.output_item.done", %{"item" => item}, state) do
    case Map.get(item, "type") do
      "function_call" ->
        tool_call = build_tool_call(item, state.tool_call_buffers)

        next_state =
          case Map.get(item, "call_id") do
            call_id when is_binary(call_id) ->
              update_in(state, [:tool_call_buffers], &Map.delete(&1, call_id))

            _other ->
              state
          end

        {[], update_in(next_state, [:pending_tool_calls], &(&1 ++ [tool_call]))}

      _other ->
        {[], state}
    end
  end

  defp handle_stream_event("response.completed", payload, state) do
    response = Map.get(payload, "response") || payload
    tool_calls = state.pending_tool_calls

    final_chunk = %{
      delta: "",
      finish_reason: stream_finish_reason(Map.get(response, "status"), tool_calls),
      tool_calls: tool_calls,
      token_usage: parse_token_usage(Map.get(response, "usage"))
    }

    {[final_chunk], %{state | pending_tool_calls: [], tool_call_buffers: %{}}}
  end

  defp handle_stream_event(_event, _payload, state), do: {[], state}

  defp delta_text(%{"delta" => delta}) when is_binary(delta), do: delta
  defp delta_text(%{"delta" => %{"text" => delta}}) when is_binary(delta), do: delta
  defp delta_text(%{"part" => %{"text" => delta}}) when is_binary(delta), do: delta
  defp delta_text(_payload), do: ""

  defp parse_chat_response(%{"output" => output} = body) when is_list(output) do
    {:ok,
     %ProviderResponse{
       content: parse_output_text(output),
       tool_calls: parse_output_tool_calls(output),
       token_usage: parse_token_usage(Map.get(body, "usage")),
       model: Map.get(body, "model"),
       finish_reason: Map.get(body, "status")
     }}
  end

  defp parse_chat_response(_body), do: {:error, :invalid_response}

  defp parse_output_text(output) do
    output
    |> Enum.flat_map(fn
      %{"type" => "message", "content" => content} when is_list(content) ->
        Enum.flat_map(content, fn
          %{"type" => "output_text", "text" => text} when is_binary(text) -> [text]
          _part -> []
        end)

      _item ->
        []
    end)
    |> Enum.join("")
  end

  defp parse_output_tool_calls(output) do
    Enum.flat_map(output, fn
      %{"type" => "function_call"} = item ->
        [build_tool_call(item, %{})]

      _item ->
        []
    end)
  end

  defp build_tool_call(item, buffers) do
    call_id = Map.get(item, "call_id") || ""
    buffer = Map.get(buffers, call_id, %{})
    item_id = Map.get(item, "id") || buffer[:id]

    %ToolCall{
      id: tool_call_identifier(call_id, item_id),
      name: Map.get(item, "name") || buffer[:name] || "",
      arguments: parse_arguments(Map.get(item, "arguments") || buffer[:arguments])
    }
  end

  defp parse_token_usage(nil), do: nil

  defp parse_token_usage(usage) when is_map(usage) do
    input = integer_field(usage, "input_tokens", 0)
    output = integer_field(usage, "output_tokens", 0)
    total = integer_field(usage, "total_tokens", input + output)

    %TokenUsage{input: input, output: output, total: total}
  end

  defp decode_body(body) when is_map(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_response}
    end
  end

  defp decode_body(_body), do: {:error, :invalid_response}

  defp sanitize_http_error(%Req.Response{status: 401}), do: {:error, :unauthorized}

  defp sanitize_http_error(%Req.Response{status: status}) when status >= 500,
    do: {:error, :server_error}

  defp sanitize_http_error(%Req.Response{}), do: {:error, :request_failed}

  defp fetch_access_token do
    if Process.whereis(TokenManager) do
      TokenManager.get_token()
    else
      {:error, :no_token}
    end
  end

  defp fetch_account_id do
    case Keyword.get(config(), :account_id) do
      account_id when is_binary(account_id) and account_id != "" -> {:ok, account_id}
      _missing -> {:error, :missing_account_id}
    end
  end

  defp config do
    Application.get_env(:elixir_claw, __MODULE__, [])
  end

  defp responses_url do
    base_url =
      config()
      |> Keyword.get(:base_url, @default_base_url)
      |> String.trim_trailing("/")

    if String.ends_with?(base_url, "/backend-api/codex/responses") do
      base_url
    else
      base_url <> "/backend-api/codex/responses"
    end
  end

  defp message_role(message), do: Map.get(message, :role) || Map.get(message, "role")
  defp message_content(message), do: Map.get(message, :content) || Map.get(message, "content")

  defp message_content_text(message) do
    case message_content(message) do
      content when is_binary(content) -> content
      _other -> ""
    end
  end

  defp message_tool_call_id(message),
    do: Map.get(message, :tool_call_id) || Map.get(message, "tool_call_id")

  defp message_tool_calls(message),
    do: Map.get(message, :tool_calls) || Map.get(message, "tool_calls")

  defp tool_call_id(%ToolCall{id: id}), do: id

  defp tool_call_id(tool_call) when is_map(tool_call),
    do: Map.get(tool_call, :id) || Map.get(tool_call, "id") || ""

  defp tool_call_name(%ToolCall{name: name}), do: name

  defp tool_call_name(tool_call) when is_map(tool_call),
    do: Map.get(tool_call, :name) || Map.get(tool_call, "name") || ""

  defp tool_call_arguments(%ToolCall{arguments: arguments}), do: arguments || %{}

  defp tool_call_arguments(tool_call) when is_map(tool_call) do
    Map.get(tool_call, :arguments) || Map.get(tool_call, "arguments") || %{}
  end

  defp parse_arguments(arguments) when is_map(arguments), do: arguments

  defp parse_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, parsed} when is_map(parsed) -> parsed
      _error -> %{}
    end
  end

  defp parse_arguments(_arguments), do: %{}

  defp split_tool_call_id(tool_call_id) when is_binary(tool_call_id) and tool_call_id != "" do
    case String.split(tool_call_id, "|", parts: 2) do
      [call_id, item_id] -> {call_id, item_id}
      [call_id] -> {call_id, nil}
    end
  end

  defp split_tool_call_id(_tool_call_id), do: {"", nil}

  defp tool_call_identifier(call_id, item_id)
       when is_binary(call_id) and call_id != "" and is_binary(item_id) and item_id != "",
       do: call_id <> "|" <> item_id

  defp tool_call_identifier(call_id, _item_id) when is_binary(call_id) and call_id != "",
    do: call_id

  defp tool_call_identifier(_call_id, item_id) when is_binary(item_id) and item_id != "",
    do: item_id

  defp tool_call_identifier(_call_id, _item_id), do: ""

  defp stream_finish_reason(_status, tool_calls) when is_list(tool_calls) and tool_calls != [],
    do: :tool_calls

  defp stream_finish_reason("completed", _tool_calls), do: :stop
  defp stream_finish_reason("incomplete", _tool_calls), do: :length
  defp stream_finish_reason(_status, _tool_calls), do: nil

  defp integer_field(map, "input_tokens", default),
    do: Map.get(map, "input_tokens") || Map.get(map, :input_tokens) || default

  defp integer_field(map, "output_tokens", default),
    do: Map.get(map, "output_tokens") || Map.get(map, :output_tokens) || default

  defp integer_field(map, "total_tokens", default),
    do: Map.get(map, "total_tokens") || Map.get(map, :total_tokens) || default

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_into(opts, true), do: opts ++ [into: :self]
  defp maybe_put_into(opts, false), do: opts

  defp maybe_prepend(list, true, value), do: [value | list]
  defp maybe_prepend(list, false, _value), do: list
end
