defmodule ElixirClaw.Repo do
  use Ecto.Repo,
    otp_app: :elixir_claw,
    adapter: Ecto.Adapters.SQLite3
end
