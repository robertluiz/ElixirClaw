defmodule ElixirClaw.Providers.Anthropic do
  @moduledoc """
  Anthropic provider implementation for the messages API.
  """

  @behaviour ElixirClaw.Provider

  alias ElixirClaw.Types.{ProviderResponse, TokenUsage, ToolCall}

  @default_base_url "https://api.anthropic.com/v1"
  @default_version "2023-06-01"
  @default_models ["claude-3-5-sonnet"]

  @impl true
  def name, do: "anthropic"

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
    with {:ok, request_opts} <- request_options(messages, opts),
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
    with {:ok, request_opts} <- stream_request_options(messages, opts),
         {:ok, response} <- Req.post(request_opts),
         :ok <- validate_stream_response(response) do
      {:ok, build_stream(response.body)}
    else
      {:error, _reason} = error -> error
    end
  end

  defp request_options(messages, opts) do
    with {:ok, api_key} <- fetch_api_key() do
      {:ok,
       [
         url: messages_url(),
         headers: request_headers(api_key),
         json: request_body(messages, opts)
       ]}
    end
  end

  defp stream_request_options(messages, opts) do
    with {:ok, api_key} <- fetch_api_key() do
      body = request_body(messages, opts) |> Map.put("stream", true)

      {:ok,
       [
         url: messages_url(),
         headers: request_headers(api_key),
         json: body,
         into: :self
       ]}
    end
  end

  defp request_body(messages, opts) do
    opts = Keyword.put_new(opts, :model, List.first(models()))
    {system, formatted_messages} = format_messages(messages)

    %{
      "model" => Keyword.fetch!(opts, :model),
      "messages" => formatted_messages
    }
    |> maybe_put("system", system)
    |> maybe_put("tools", Keyword.get(opts, :tools))
  end

  defp format_messages(messages) do
    {system_messages, conversation_messages} =
      Enum.split_with(messages, fn message -> message_role(message) == "system" end)

    system =
      system_messages
      |> Enum.map(&message_content_text/1)
      |> Enum.reject(&(&1 == ""))
      |> case do
        [] -> nil
        parts -> Enum.join(parts, "\n\n")
      end

    {system, Enum.map(conversation_messages, &format_message/1)}
  end

  defp format_message(message) do
    case message_role(message) do
      "tool" ->
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => message_tool_call_id(message),
              "content" => message_content_text(message)
            }
          ]
        }

      role when role in ["assistant", "user"] ->
        %{
          "role" => role,
          "content" => format_content_blocks(message)
        }

      role ->
        %{"role" => role, "content" => message_content_text(message)}
    end
  end

  defp format_content_blocks(message) do
    text = message_content_text(message)
    tool_calls = message_tool_calls(message)

    blocks =
      []
      |> maybe_add_text_block(text)
      |> Kernel.++(format_tool_use_blocks(tool_calls))

    case {tool_calls, blocks} do
      {tool_calls, blocks} when is_list(tool_calls) and tool_calls != [] -> blocks
      {_tool_calls, [%{"type" => "text", "text" => only_text}]} -> only_text
      {_tool_calls, []} -> ""
      {_tool_calls, blocks} -> blocks
    end
  end

  defp format_tool_use_blocks(nil), do: []
  defp format_tool_use_blocks([]), do: []

  defp format_tool_use_blocks(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn
      %ToolCall{} = tool_call ->
        %{
          "type" => "tool_use",
          "id" => tool_call.id,
          "name" => tool_call.name,
          "input" => tool_call.arguments || %{}
        }

      tool_call when is_map(tool_call) ->
        %{
          "type" => "tool_use",
          "id" => Map.get(tool_call, :id) || Map.get(tool_call, "id") || "",
          "name" => Map.get(tool_call, :name) || Map.get(tool_call, "name") || "",
          "input" =>
            Map.get(tool_call, :arguments) || Map.get(tool_call, "arguments") ||
              Map.get(tool_call, :input) || Map.get(tool_call, "input") || %{}
        }
    end)
  end

  defp maybe_add_text_block(blocks, ""), do: blocks
  defp maybe_add_text_block(blocks, text), do: blocks ++ [%{"type" => "text", "text" => text}]

  defp validate_stream_response(%Req.Response{status: status, body: body})
       when status in 200..299 do
    if Enumerable.impl_for(body), do: :ok, else: {:error, :stream_error}
  end

  defp validate_stream_response(%Req.Response{} = response), do: sanitize_http_error(response)

  defp validate_chat_response(%Req.Response{status: status}) when status in 200..299, do: :ok
  defp validate_chat_response(%Req.Response{} = response), do: sanitize_http_error(response)

  defp build_stream(async_body) do
    initial_state = %{
      buffer: "",
      input_tokens: 0,
      output_tokens: 0,
      stop_reason: nil,
      blocks: %{},
      pending_tool_calls: []
    }

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

  defp handle_stream_event("message_start", %{"message" => %{"usage" => usage}}, state) do
    {[], %{state | input_tokens: integer_field(usage, "input_tokens", state.input_tokens)}}
  end

  defp handle_stream_event("content_block_start", %{"index" => index} = payload, state) do
    block = Map.get(payload, "content_block", %{})

    next_state =
      case Map.get(block, "type") do
        "tool_use" ->
          put_in(state, [:blocks, index], %{
            type: "tool_use",
            id: Map.get(block, "id", ""),
            name: Map.get(block, "name", ""),
            input_json: initial_tool_input(block)
          })

        _other ->
          state
      end

    {[], next_state}
  end

  defp handle_stream_event(
         "content_block_delta",
         %{"delta" => %{"type" => "text_delta", "text" => text}},
         state
       ) do
    {[%{delta: text, finish_reason: nil, tool_calls: [], token_usage: nil}], state}
  end

  defp handle_stream_event(
         "content_block_delta",
         %{
           "index" => index,
           "delta" => %{"type" => "input_json_delta", "partial_json" => partial_json}
         },
         state
       ) do
    next_state =
      update_in(state, [:blocks, index], fn
        nil -> %{type: "tool_use", id: "", name: "", input_json: partial_json}
        block -> Map.update(block, :input_json, partial_json, &(&1 <> partial_json))
      end)

    {[], next_state}
  end

  defp handle_stream_event("content_block_stop", %{"index" => index}, state) do
    case get_in(state, [:blocks, index]) do
      %{type: "tool_use"} = block ->
        tool_call = %ToolCall{
          id: block.id,
          name: block.name,
          arguments: decode_partial_json(block.input_json)
        }

        next_state =
          state
          |> update_in([:pending_tool_calls], &(&1 ++ [tool_call]))
          |> update_in([:blocks], &Map.delete(&1, index))

        {[], next_state}

      _other ->
        {[], state}
    end
  end

  defp handle_stream_event("message_delta", payload, state) do
    stop_reason = payload |> Map.get("delta", %{}) |> Map.get("stop_reason")
    usage = Map.get(payload, "usage", %{})

    next_state = %{
      state
      | output_tokens: integer_field(usage, "output_tokens", state.output_tokens),
        stop_reason: stop_reason || state.stop_reason
    }

    final_chunk = %{
      delta: "",
      finish_reason: finish_reason_atom(next_state.stop_reason),
      tool_calls: next_state.pending_tool_calls,
      token_usage: %TokenUsage{
        input: next_state.input_tokens,
        output: next_state.output_tokens,
        total: next_state.input_tokens + next_state.output_tokens
      }
    }

    {[final_chunk], %{next_state | pending_tool_calls: []}}
  end

  defp handle_stream_event("message_stop", _payload, state), do: {[], state}
  defp handle_stream_event(_event, _payload, state), do: {[], state}

  defp parse_chat_response(%{"content" => content_blocks} = body) when is_list(content_blocks) do
    {:ok,
     %ProviderResponse{
       content: parse_text_content(content_blocks),
       tool_calls: parse_tool_calls(content_blocks),
       token_usage: parse_token_usage(Map.get(body, "usage")),
       model: Map.get(body, "model"),
       finish_reason: Map.get(body, "stop_reason")
     }}
  end

  defp parse_chat_response(_body), do: {:error, :invalid_response}

  defp parse_text_content(content_blocks) do
    content_blocks
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _block -> []
    end)
    |> Enum.join("")
  end

  defp parse_tool_calls(content_blocks) do
    Enum.flat_map(content_blocks, fn
      %{"type" => "tool_use", "id" => id, "name" => name} = block ->
        [
          %ToolCall{
            id: id,
            name: name,
            arguments: Map.get(block, "input", %{})
          }
        ]

      _block ->
        []
    end)
  end

  defp parse_token_usage(nil), do: nil

  defp parse_token_usage(usage) when is_map(usage) do
    input = integer_field(usage, "input_tokens", 0)
    output = integer_field(usage, "output_tokens", 0)

    %TokenUsage{input: input, output: output, total: input + output}
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

  defp fetch_api_key do
    case Keyword.get(config(), :api_key) do
      api_key when is_binary(api_key) and api_key != "" -> {:ok, api_key}
      _missing -> {:error, :missing_api_key}
    end
  end

  defp config do
    Application.get_env(:elixir_claw, __MODULE__, [])
  end

  defp request_headers(api_key) do
    [
      {"content-type", "application/json"},
      {"x-api-key", api_key},
      {"anthropic-version", Keyword.get(config(), :anthropic_version, @default_version)}
    ]
  end

  defp messages_url do
    config()
    |> Keyword.get(:base_url, @default_base_url)
    |> String.trim_trailing("/")
    |> Kernel.<>("/messages")
  end

  defp message_role(message), do: Map.get(message, :role) || Map.get(message, "role")

  defp message_tool_call_id(message),
    do: Map.get(message, :tool_call_id) || Map.get(message, "tool_call_id")

  defp message_tool_calls(message),
    do: Map.get(message, :tool_calls) || Map.get(message, "tool_calls")

  defp message_content_text(message) do
    case Map.get(message, :content) || Map.get(message, "content") do
      content when is_binary(content) -> content
      nil -> ""
      content when is_list(content) -> content |> parse_text_content()
      other -> to_string(other)
    end
  end

  defp finish_reason_atom(nil), do: nil
  defp finish_reason_atom("end_turn"), do: :stop
  defp finish_reason_atom("tool_use"), do: :tool_calls
  defp finish_reason_atom("max_tokens"), do: :length
  defp finish_reason_atom("pause_turn"), do: :pause
  defp finish_reason_atom(_other), do: nil

  defp initial_tool_input(%{"input" => input}) when map_size(input) > 0, do: Jason.encode!(input)
  defp initial_tool_input(_block), do: ""

  defp decode_partial_json(""), do: %{}

  defp decode_partial_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp integer_field(map, "input_tokens", default),
    do: Map.get(map, "input_tokens") || Map.get(map, :input_tokens) || default

  defp integer_field(map, "output_tokens", default),
    do: Map.get(map, "output_tokens") || Map.get(map, :output_tokens) || default

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
