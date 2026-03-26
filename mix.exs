defmodule ElixirClaw.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixir_claw,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: releases(),
      aliases: aliases()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp releases do
    [
      elixir_claw: [
        include_erts: true,
        applications: [runtime_tools: :permanent]
      ]
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
      {:ecto, "~> 3.13"},
      {:exqlite, "~> 0.35"},
      {:toml, "~> 0.7"},
      {:oauth2, "~> 2.1"},
      {:phoenix_pubsub, "~> 2.1"},
      {:bandit, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.1", only: :test},
      {:bypass, "~> 2.1", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["claw.install"]
    ]
  end
end
