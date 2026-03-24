defmodule ElixirClaw.Types.ToolCall do
  @moduledoc """
  Represents a single tool call request or response within a conversation.
  """

  @enforce_keys [:id, :name]
  defstruct [
    :id,
    :name,
    arguments: %{},
    result: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          arguments: map(),
          result: any()
        }
end
