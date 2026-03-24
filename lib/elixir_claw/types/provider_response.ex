defmodule ElixirClaw.Types.ProviderResponse do
  @moduledoc """
  Represents a completed response from an LLM provider.
  """

  @enforce_keys [:content]
  defstruct [
    :content,
    tool_calls: nil,
    token_usage: nil,
    model: nil,
    finish_reason: nil
  ]

  @type t :: %__MODULE__{
          content: String.t() | nil,
          tool_calls: list() | nil,
          token_usage: ElixirClaw.Types.TokenUsage.t() | nil,
          model: String.t() | nil,
          finish_reason: String.t() | nil
        }
end
