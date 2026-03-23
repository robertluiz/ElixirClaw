defmodule ElixirClaw.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE messages (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system', 'tool')),
      content TEXT NOT NULL,
      tool_calls TEXT,
      tool_call_id TEXT,
      token_count INTEGER NOT NULL DEFAULT 0,
      inserted_at TEXT NOT NULL,
      FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
    )
    """)

    create index(:messages, [:session_id])
  end

  def down do
    drop index(:messages, [:session_id])
    execute("DROP TABLE messages")
  end
end
