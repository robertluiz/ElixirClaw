defmodule ElixirClaw.OpenCode.Schema.Part do
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "parts" do
    field(:message_id, :string)
    field(:session_id, :string)
    field(:time_created, :integer)
    field(:data, :string)
  end
end
