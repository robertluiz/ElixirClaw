import Config

config :elixir_claw,
  ecto_repos: [ElixirClaw.Repo]

# Import environment specific config
import_config "#{config_env()}.exs"
