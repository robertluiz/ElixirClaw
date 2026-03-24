defmodule ElixirClaw.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ElixirClaw.Repo,
      {Phoenix.PubSub, name: ElixirClaw.PubSub},
      {Registry, keys: :unique, name: ElixirClaw.SessionRegistry},
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
end
