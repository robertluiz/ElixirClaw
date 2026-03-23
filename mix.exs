defmodule ElixirClaw.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixir_claw,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ElixirClaw.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:req_llm, "~> 1.8"},
      {:telegex, "~> 1.8"},
      {:nostrum, "~> 0.10", runtime: false},
      {:hermes_mcp, "~> 0.14"},
      {:jason, "~> 1.4"},
      {:ecto_sqlite3, "~> 0.15"},
      {:toml, "~> 0.7"},
      {:oauth2, "~> 2.1"},
      {:phoenix_pubsub, "~> 2.1"},
      {:mox, "~> 1.1", only: :test},
      {:bypass, "~> 2.1", only: :test}
    ]
  end
end
