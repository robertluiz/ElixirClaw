defmodule ElixirClaw.Schema.GraphEdge do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :naive_datetime]

  schema "graph_edges" do
    field(:session_id, :binary_id)
    field(:source_node_id, :binary_id)
    field(:target_node_id, :binary_id)
    field(:relation_type, :string)
    field(:metadata, :map, default: %{})
    field(:valid_at, :naive_datetime)
    field(:invalid_at, :naive_datetime)

    timestamps(updated_at: false)
  end

  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [
      :id,
      :session_id,
      :source_node_id,
      :target_node_id,
      :relation_type,
      :metadata,
      :valid_at,
      :invalid_at
    ])
    |> validate_required([:source_node_id, :target_node_id, :relation_type])
  end
end
