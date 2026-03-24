defmodule ElixirClaw.Types.Session do
  @moduledoc """
  Represents an in-memory agent session (not the Ecto schema).
  Sensitive metadata is automatically redacted in inspect output.
  """

  @enforce_keys [:id, :channel, :channel_user_id, :provider]
  defstruct [
    :id,
    :channel,
    :channel_user_id,
    :provider,
    model: nil,
    messages: [],
    token_count_in: 0,
    token_count_out: 0,
    metadata: %{},
    created_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          channel: String.t(),
          channel_user_id: String.t(),
          provider: String.t(),
          model: String.t() | nil,
          messages: list(),
          token_count_in: non_neg_integer(),
          token_count_out: non_neg_integer(),
          metadata: map(),
          created_at: DateTime.t() | nil
        }

  @sensitive_keys MapSet.new(["api_key", "token", "secret", "password"])

  @doc """
  Redacts sensitive keys in a metadata map. Safe to call on any map.
  """
  @spec redact_metadata(map() | any()) :: map() | any()
  def redact_metadata(metadata) when is_map(metadata) do
    Enum.into(metadata, %{}, fn {key, value} ->
      if MapSet.member?(@sensitive_keys, to_string(key)),
        do: {key, "[REDACTED]"},
        else: {key, value}
    end)
  end

  def redact_metadata(other), do: other
end

defimpl Inspect, for: ElixirClaw.Types.Session do
  import Inspect.Algebra
  alias ElixirClaw.Types.Session

  def inspect(session, opts) do
    redacted = %{session | metadata: Session.redact_metadata(session.metadata)}
    concat(["#Session<", to_doc(Map.from_struct(redacted), opts), ">"])
  end
end
