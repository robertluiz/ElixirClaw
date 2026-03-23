import Config

config :elixir_claw, :env, :test

config :elixir_claw, ElixirClaw.Repo,
  database: ":memory:",
  pool: Ecto.Adapters.SQL.Sandbox,
  journal_mode: :wal,
  pool_size: 10
