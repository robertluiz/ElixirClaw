defmodule ElixirClaw.Providers.CopilotBYOK do
  @moduledoc """
  Copilot BYOK provider for OpenAI-compatible chat completions.
  """

  @behaviour ElixirClaw.Provider

  require Logger

  alias ElixirClaw.Providers.OpenAICompat
  alias ElixirClaw.Types.ProviderResponse

  @default_base_url "https://api.openai.com/v1"

  @impl true
  def name, do: "copilot_byok"

  @impl true
  def models do
    config()
    |> Keyword.get(:models, [])
    |> List.wrap()
    |> case do
      [] ->
        config()
        |> Keyword.get(:model)
        |> List.wrap()

      configured_models ->
        configured_models
    end
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
    with {:ok, api_key} <- fetch_required_config(:api_key, :missing_api_key),
         {:ok, model} <- resolve_model(opts) do
      warn_if_insecure_base_url()

      {:ok,
       [
         url: chat_completions_url(),
         auth: {:bearer, api_key},
         headers: [{"content-type", "application/json"}],
         json: request_body(messages, model, opts)
       ]}
    end
  end

  defp stream_request_options(messages, opts) do
    with {:ok, api_key} <- fetch_required_config(:api_key, :missing_api_key),
         {:ok, model} <- resolve_model(opts) do
      warn_if_insecure_base_url()

      {:ok,
       [
         url: chat_completions_url(),
         auth: {:bearer, api_key},
         headers: [{"content-type", "application/json"}],
         json:
           messages
           |> request_body(model, opts)
           |> Map.put("stream", true)
           |> Map.put("stream_options", %{"include_usage" => true}),
         into: :self
       ]}
    end
  end

  defp request_body(messages, model, opts) do
    %{
      "model" => model,
      "messages" => OpenAICompat.format_messages(messages)
    }
    |> maybe_put("tools", Keyword.get(opts, :tools))
  end

  defp validate_stream_response(%Req.Response{status: status, body: body}) when status in 200..299 do
    if Enumerable.impl_for(body), do: :ok, else: {:error, :stream_error}
  end

  defp validate_stream_response(%Req.Response{} = response), do: sanitize_http_error(response)

  defp validate_chat_response(%Req.Response{status: status}) when status in 200..299, do: :ok
  defp validate_chat_response(%Req.Response{} = response), do: sanitize_http_error(response)

  defp build_stream(async_body) do
    Stream.transform(async_body, "", &parse_sse_chunk/2)
  end

  defp parse_sse_chunk(chunk, buffer) do
    {events, rest} = split_events(buffer <> chunk)
    {Enum.flat_map(events, &parse_event/1), rest}
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

  defp parse_event("data: [DONE]"), do: []

  defp parse_event(event) do
    event
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&String.replace_prefix(&1, "data: ", ""))
    |> Enum.flat_map(&parse_event_payload/1)
  end

  defp parse_event_payload(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} ->
        [
          %{
            delta: decoded |> first_choice() |> delta_content(),
            finish_reason: decoded |> first_choice() |> finish_reason_atom(),
            tool_calls: decoded |> first_choice() |> delta_tool_calls(),
            token_usage: OpenAICompat.parse_token_usage(decoded["usage"])
          }
        ]

      {:error, _reason} ->
        []
    end
  end

  defp parse_chat_response(%{"choices" => [choice | _]} = body) do
    message = Map.get(choice, "message", %{})

    {:ok,
     %ProviderResponse{
       content: Map.get(message, "content"),
       tool_calls: OpenAICompat.parse_tool_calls(Map.get(message, "tool_calls")),
       token_usage: OpenAICompat.parse_token_usage(Map.get(body, "usage")),
       model: Map.get(body, "model"),
       finish_reason: Map.get(choice, "finish_reason")
     }}
  end

  defp parse_chat_response(_body), do: {:error, :invalid_response}

  defp decode_body(body) when is_map(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_response}
    end
  end

  defp decode_body(_body), do: {:error, :invalid_response}

  defp sanitize_http_error(%Req.Response{status: 401}), do: {:error, :unauthorized}
  defp sanitize_http_error(%Req.Response{status: status}) when status >= 500, do: {:error, :server_error}
  defp sanitize_http_error(%Req.Response{}), do: {:error, :request_failed}

  defp fetch_required_config(key, error) do
    case Keyword.get(config(), key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, error}
    end
  end

  defp resolve_model(opts) do
    case Keyword.get(opts, :model) || Keyword.get(config(), :model) || List.first(models()) do
      model when is_binary(model) and model != "" -> {:ok, model}
      _missing -> {:error, :missing_model}
    end
  end

  defp config do
    Application.get_env(:elixir_claw, __MODULE__, [])
  end

  defp warn_if_insecure_base_url do
    base_url = base_url()

    if String.starts_with?(base_url, "http://") do
      Logger.warning("Copilot BYOK base_url uses insecure HTTP: #{base_url}")
    end

    :ok
  end

  defp chat_completions_url do
    base_url =
      base_url()
      |> String.trim_trailing("/")

    if String.ends_with?(base_url, "/chat/completions") do
      base_url
    else
      base_url <> "/chat/completions"
    end
  end

  defp base_url do
    Keyword.get(config(), :base_url, @default_base_url)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp first_choice(%{"choices" => [choice | _]}), do: choice
  defp first_choice(_payload), do: %{}

  defp delta_content(%{"delta" => %{"content" => content}}) when is_binary(content), do: content
  defp delta_content(_choice), do: ""

  defp delta_tool_calls(%{"delta" => %{"tool_calls" => tool_calls}}),
    do: OpenAICompat.parse_tool_calls(tool_calls)

  defp delta_tool_calls(_choice), do: []

  defp finish_reason_atom(%{"finish_reason" => nil}), do: nil
  defp finish_reason_atom(%{"finish_reason" => "stop"}), do: :stop
  defp finish_reason_atom(%{"finish_reason" => "length"}), do: :length
  defp finish_reason_atom(%{"finish_reason" => "tool_calls"}), do: :tool_calls
  defp finish_reason_atom(%{"finish_reason" => "content_filter"}), do: :content_filter
  defp finish_reason_atom(_choice), do: nil
end
