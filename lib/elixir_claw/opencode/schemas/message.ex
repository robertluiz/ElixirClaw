defmodule ElixirClaw.OpenCode.Schema.Message do
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "messages" do
    field(:session_id, :string)
    field(:time_created, :integer)
    field(:time_updated, :integer)
    field(:data, :string)
  end
end
