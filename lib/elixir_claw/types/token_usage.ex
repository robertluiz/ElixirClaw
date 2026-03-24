defmodule ElixirClaw.Types.TokenUsage do
  @moduledoc """
  Tracks input/output/total token usage for a provider call or session.
  """

  defstruct input: 0, output: 0, total: 0

  @type t :: %__MODULE__{
          input: non_neg_integer(),
          output: non_neg_integer(),
          total: non_neg_integer()
        }

  @doc """
  Adds two TokenUsage structs together, recalculating the total.
  """
  @spec add(t(), t()) :: t()
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    input = a.input + b.input
    output = a.output + b.output
    %__MODULE__{input: input, output: output, total: input + output}
  end
end
