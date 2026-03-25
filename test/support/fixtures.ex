defmodule ElixirClaw.Test.Fixtures do
  @moduledoc """
  Test fixtures for building in-memory structs used across tests.
  Uses sensible defaults so callers only override what matters.
  """

  alias ElixirClaw.Types.{Message, ProviderResponse, Session, TokenUsage, ToolCall}

  @doc """
  Build a `%Message{}` struct with defaults.

  ## Options
    - `:role` — "user" | "assistant" | "system" | "tool" (default: "user")
    - `:content` — string content (default: "test message")
    - `:token_count` — integer (default: 12)
    - `:tool_calls` — list (default: nil)
    - `:tool_call_id` — string (default: nil)
  """
  @spec build_message(keyword()) :: Message.t()
  def build_message(opts \\ []) do
    %Message{
      role: Keyword.get(opts, :role, "user"),
      content: Keyword.get(opts, :content, "test message"),
      token_count: Keyword.get(opts, :token_count, 12),
      tool_calls: Keyword.get(opts, :tool_calls, nil),
      tool_call_id: Keyword.get(opts, :tool_call_id, nil)
    }
  end

  @doc """
  Build a `%Session{}` struct with defaults.

  ## Options
    - `:id` — session ID string (default: auto-generated UUID-style)
    - `:channel` — channel name (default: "cli")
    - `:channel_user_id` — user ID (default: "test-user")
    - `:provider` — provider name (default: "openai")
    - `:model` — model name (default: nil)
    - `:messages` — list of Messages (default: [])
    - `:metadata` — map (default: %{})
  """
  @spec build_session(keyword()) :: Session.t()
  def build_session(opts \\ []) do
    %Session{
      id: Keyword.get(opts, :id, "test-session-#{System.unique_integer([:positive])}"),
      channel: Keyword.get(opts, :channel, "cli"),
      channel_user_id: Keyword.get(opts, :channel_user_id, "test-user"),
      provider: Keyword.get(opts, :provider, "openai"),
      model: Keyword.get(opts, :model, nil),
      messages: Keyword.get(opts, :messages, []),
      token_count_in: Keyword.get(opts, :token_count_in, 0),
      token_count_out: Keyword.get(opts, :token_count_out, 0),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Build a `%TokenUsage{}` with defaults.
  """
  @spec build_token_usage(keyword()) :: TokenUsage.t()
  def build_token_usage(opts \\ []) do
    input = Keyword.get(opts, :input, 10)
    output = Keyword.get(opts, :output, 20)
    %TokenUsage{input: input, output: output, total: input + output}
  end

  @doc """
  Build a `%ProviderResponse{}` with defaults.
  """
  @spec build_provider_response(keyword()) :: ProviderResponse.t()
  def build_provider_response(opts \\ []) do
    %ProviderResponse{
      content: Keyword.get(opts, :content, "Test response"),
      tool_calls: Keyword.get(opts, :tool_calls, nil),
      token_usage: Keyword.get(opts, :token_usage, build_token_usage()),
      model: Keyword.get(opts, :model, "gpt-4o-mini"),
      finish_reason: Keyword.get(opts, :finish_reason, "stop")
    }
  end

  @doc """
  Build a `%ToolCall{}` with defaults.
  """
  @spec build_tool_call(keyword()) :: ToolCall.t()
  def build_tool_call(opts \\ []) do
    %ToolCall{
      id: Keyword.get(opts, :id, "tool-#{System.unique_integer([:positive])}"),
      name: Keyword.get(opts, :name, "test_tool"),
      arguments: Keyword.get(opts, :arguments, %{}),
      result: Keyword.get(opts, :result, nil)
    }
  end
end
