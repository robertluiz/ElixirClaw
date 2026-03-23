import Config

config :elixir_claw,
  ecto_repos: [ElixirClaw.Repo]

config :elixir_claw, ElixirClaw.Repo,
  database: "elixir_claw_dev.db",
  journal_mode: :wal,
  cache_size: -64_000,
  temp_store: :memory,
  pool_size: 5

# Import environment specific config
import_config "#{config_env()}.exs"
