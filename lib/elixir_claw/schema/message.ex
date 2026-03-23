defmodule ElixirClaw.Schema.Message do
  use Ecto.Schema

  import Ecto.Changeset

  alias ElixirClaw.Schema.Session

  @roles ~w(user assistant system tool)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    field :role, :string
    field :content, :string
    field :tool_calls, :map
    field :tool_call_id, :string
    field :token_count, :integer, default: 0

    belongs_to :session, Session

    timestamps(updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :session_id,
      :role,
      :content,
      :tool_calls,
      :tool_call_id,
      :token_count
    ])
    |> validate_required([:session_id, :role, :content])
    |> validate_inclusion(:role, @roles)
    |> foreign_key_constraint(:session_id)
  end
end
