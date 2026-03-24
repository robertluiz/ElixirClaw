defmodule ElixirClaw.OpenCode.Schema.Session do
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "sessions" do
    field(:project_id, :string)
    field(:title, :string)
    field(:directory, :string)
    field(:time_created, :integer)
    field(:time_updated, :integer)
    field(:summary_diffs, :string)
    field(:parent_id, :string)
  end
end
