defmodule ElixirClaw.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :channel, :string, null: false
      add :channel_user_id, :string, null: false
      add :provider, :string, null: false
      add :model, :string
      add :token_count_in, :integer, null: false, default: 0
      add :token_count_out, :integer, null: false, default: 0
      add :metadata, :map

      timestamps()
    end
  end
end
