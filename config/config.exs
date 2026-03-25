import Config

config :elixir_claw, ElixirClaw.Repo,
  engine: :sqlite,
  path: "elixir_claw_dev.cozo.db"

# Import environment specific config
import_config "#{config_env()}.exs"
