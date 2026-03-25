defmodule ElixirClaw.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @memory_consolidator Module.concat([ElixirClaw.Agent.Memory, Consolidator])

  @impl true
  def start(_type, _args) do
    ensure_optional_test_modules_loaded()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ElixirClaw.Supervisor]
    case Supervisor.start_link(child_specs(), opts) do
      {:ok, _pid} = result ->
        :ok = ElixirClaw.Tools.Bootstrap.register_builtin_tools()
        result

      other ->
        other
    end
  end

  def child_specs do
    [
      ElixirClaw.Repo,
      {Registry, keys: :unique, name: ElixirClaw.SessionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: ElixirClaw.SessionSupervisor},
      {Phoenix.PubSub, name: ElixirClaw.PubSub},
      {Task.Supervisor, name: ElixirClaw.ToolSupervisor},
      {ElixirClaw.Tools.Registry, name: ElixirClaw.Tools.Registry},
      ElixirClaw.Agent.MemoryGraphIndexer,
      ElixirClaw.Providers.Codex.TokenManager,
      ElixirClaw.Providers.Copilot.TokenManager,
      ElixirClaw.MCP.Supervisor
    ] ++ optional_memory_consolidator_child_specs() ++ [ElixirClaw.Channels.Supervisor]
  end

  defp ensure_optional_test_modules_loaded do
    for module <- [
          ElixirClaw.MockProvider,
          ElixirClaw.MockChannel,
          ElixirClaw.MockTool,
          ElixirClaw.MockDiscordAPI,
          ElixirClaw.MockDiscordSessionManager,
          ElixirClaw.MockDiscordAgentLoop,
          ElixirClaw.MockHTTPClient,
          ElixirClaw.MockStdioClient,
          ElixirClaw.MockTelegex
        ] do
      _ = Code.ensure_loaded?(module)
    end

    :ok
  end

  defp optional_memory_consolidator_child_specs do
    cond do
      not Code.ensure_loaded?(@memory_consolidator) ->
        []

      function_exported?(@memory_consolidator, :child_spec, 1) ->
        [@memory_consolidator]

      function_exported?(@memory_consolidator, :start_link, 1) ->
        [{@memory_consolidator, []}]

      function_exported?(@memory_consolidator, :start_link, 0) ->
        [%{id: @memory_consolidator, start: {@memory_consolidator, :start_link, []}}]

      true ->
        []
    end
  end
end
