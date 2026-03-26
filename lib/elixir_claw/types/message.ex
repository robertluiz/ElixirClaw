defmodule ElixirClaw.Types.Message do
  @moduledoc """
  Represents a single message in a conversation (user, assistant, tool, system).
  """

  @enforce_keys [:role, :content]
  defstruct [
    :role,
    :content,
    tool_calls: nil,
    tool_call_id: nil,
    token_count: 0,
    timestamp: nil
  ]

  @type t :: %__MODULE__{
          role: String.t(),
          content: String.t() | [map()] | nil,
          tool_calls: list() | nil,
          tool_call_id: String.t() | nil,
          token_count: non_neg_integer(),
          timestamp: DateTime.t() | nil
        }

  @doc """
  Returns a rough token estimate (content length ÷ 4).
  """
  @spec estimated_tokens(t()) :: non_neg_integer()
  def estimated_tokens(%__MODULE__{content: content}) when is_binary(content) do
    div(String.length(content), 4)
  end

  def estimated_tokens(%__MODULE__{content: content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{text: text} when is_binary(text) -> text
      _other -> ""
    end)
    |> Enum.join(" ")
    |> then(&div(String.length(&1), 4))
  end

  def estimated_tokens(%__MODULE__{}), do: 0
end
