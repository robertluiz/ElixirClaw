defmodule ElixirClaw.Providers.OpenAICompat do
  @moduledoc """
  Shared OpenAI-compatible formatting and parsing helpers.
  """

  alias ElixirClaw.Types.{TokenUsage, ToolCall}

  @spec format_messages([map()]) :: [map()]
  def format_messages(messages) when is_list(messages) do
    Enum.map(messages, &format_message/1)
  end

  @spec parse_tool_calls(list() | nil) :: [ToolCall.t()]
  def parse_tool_calls(nil), do: []
  def parse_tool_calls([]), do: []

  def parse_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tool_call ->
      function = Map.get(tool_call, "function") || Map.get(tool_call, :function) || %{}

      %ToolCall{
        id: Map.get(tool_call, "id") || Map.get(tool_call, :id) || "",
        name: Map.get(function, "name") || Map.get(function, :name) || "",
        arguments:
          function
          |> Map.get("arguments", Map.get(function, :arguments, %{}))
          |> parse_arguments()
      }
    end)
  end

  @spec parse_token_usage(map() | nil) :: TokenUsage.t() | nil
  def parse_token_usage(nil), do: nil

  def parse_token_usage(usage) when is_map(usage) do
    input = integer_field(usage, "prompt_tokens", 0)
    output = integer_field(usage, "completion_tokens", 0)
    total = integer_field(usage, "total_tokens", input + output)

    %TokenUsage{input: input, output: output, total: total}
  end

  defp format_message(%{role: role, content: content} = message) do
    message
    |> Map.take([:role, :content, :tool_call_id, :tool_calls])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
    |> Map.put(:role, role)
    |> Map.put(:content, content)
    |> maybe_format_tool_calls(message)
  end

  defp format_message(message) when is_map(message) do
    role = Map.get(message, :role) || Map.get(message, "role")
    content = Map.get(message, :content) || Map.get(message, "content")
    tool_call_id = Map.get(message, :tool_call_id) || Map.get(message, "tool_call_id")
    tool_calls = Map.get(message, :tool_calls) || Map.get(message, "tool_calls")

    %{}
    |> maybe_put("role", role)
    |> maybe_put("content", content)
    |> maybe_put("tool_call_id", tool_call_id)
    |> maybe_put("tool_calls", format_tool_calls(tool_calls))
  end

  defp maybe_format_tool_calls(formatted, %{tool_calls: tool_calls}) do
    Map.put(formatted, :tool_calls, format_tool_calls(tool_calls))
  end

  defp maybe_format_tool_calls(formatted, _message), do: formatted

  defp format_tool_calls(nil), do: nil
  defp format_tool_calls([]), do: []

  defp format_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn
      %ToolCall{} = tool_call ->
        %{
          "id" => tool_call.id,
          "type" => "function",
          "function" => %{
            "name" => tool_call.name,
            "arguments" => Jason.encode!(tool_call.arguments || %{})
          }
        }

      tool_call when is_map(tool_call) ->
        tool_call
    end)
  end

  defp parse_arguments(arguments) when is_map(arguments), do: arguments

  defp parse_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, parsed} when is_map(parsed) -> parsed
      _ -> %{}
    end
  end

  defp parse_arguments(_arguments), do: %{}

  defp integer_field(map, "prompt_tokens", default),
    do: Map.get(map, "prompt_tokens") || Map.get(map, :prompt_tokens) || default

  defp integer_field(map, "completion_tokens", default),
    do: Map.get(map, "completion_tokens") || Map.get(map, :completion_tokens) || default

  defp integer_field(map, "total_tokens", default),
    do: Map.get(map, "total_tokens") || Map.get(map, :total_tokens) || default

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, "content", value) when is_list(value), do: Map.put(map, "content", value)
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
