defmodule ElixirClaw.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    ensure_optional_test_modules_loaded()

    children = [
      ElixirClaw.Repo,
      {Phoenix.PubSub, name: ElixirClaw.PubSub},
      {Registry, keys: :unique, name: ElixirClaw.SessionRegistry},
      {ElixirClaw.Tools.Registry, name: ElixirClaw.Tools.Registry},
      {Task.Supervisor, name: ElixirClaw.ToolSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: ElixirClaw.SessionSupervisor}
      # Starts a worker by calling: ElixirClaw.Worker.start_link(arg)
      # {ElixirClaw.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ElixirClaw.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp ensure_optional_test_modules_loaded do
    for module <- [ElixirClaw.MockProvider, ElixirClaw.MockChannel, ElixirClaw.MockTool] do
      _ = Code.ensure_loaded?(module)
    end

    :ok
  end
end
