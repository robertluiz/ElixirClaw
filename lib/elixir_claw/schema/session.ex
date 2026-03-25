defmodule ElixirClaw.Schema.Session do
  use Ecto.Schema

  import Ecto.Changeset

  alias ElixirClaw.Schema.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sessions" do
    field(:channel, :string)
    field(:channel_user_id, :string)
    field(:provider, :string)
    field(:model, :string)
    field(:token_count_in, :integer, default: 0)
    field(:token_count_out, :integer, default: 0)
    field(:metadata, :map)

    has_many(:messages, Message)

    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :channel,
      :channel_user_id,
      :provider,
      :model,
      :token_count_in,
      :token_count_out,
      :metadata
    ])
    |> validate_required([:channel, :channel_user_id, :provider])
    |> validate_length(:channel, max: 255)
    |> validate_length(:channel_user_id, max: 255)
    |> validate_length(:provider, max: 255)
  end
end
