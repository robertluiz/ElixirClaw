import Config

config :elixir_claw, :env, :test

config :elixir_claw, ElixirClaw.Repo,
  engine: :mem,
  path: "test/fixtures/elixir_claw_test.cozo.db"

config :elixir_claw, cli_enabled: false
