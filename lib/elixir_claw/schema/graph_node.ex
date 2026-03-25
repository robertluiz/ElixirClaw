defmodule ElixirClaw.Schema.GraphNode do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :naive_datetime]

  schema "graph_nodes" do
    field :session_id, :binary_id
    field :node_type, :string
    field :scope, :string
    field :name, :string
    field :content, :string
    field :metadata, :map, default: %{}
    field :valid_from, :naive_datetime
    field :valid_until, :naive_datetime
    field :confidence, :float, default: 1.0

    timestamps()
  end

  def changeset(node, attrs) do
    node
    |> cast(attrs, [:id, :session_id, :node_type, :scope, :name, :content, :metadata, :valid_from, :valid_until, :confidence])
    |> validate_required([:node_type, :scope, :name, :content])
  end
end
