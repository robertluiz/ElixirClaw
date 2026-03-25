defmodule ElixirClaw.ApplicationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ElixirClaw.Application, as: ClawApplication
  alias ElixirClaw.Channels.Supervisor, as: ChannelsSupervisor
  alias ElixirClaw.MCP.Supervisor, as: MCPSupervisor

  @env_keys [:channels, :cli_enabled, :telegram_enabled, :discord_enabled, :mcp_servers]

  setup do
    previous_env = Map.new(@env_keys, fn key -> {key, Application.get_env(:elixir_claw, key)} end)

    on_exit(fn ->
      Enum.each(previous_env, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:elixir_claw, key),
          else: Application.put_env(:elixir_claw, key, value)
      end)
    end)

    :ok
  end

  describe "child_specs/0" do
    test "returns the full top-level supervision tree in startup order" do
      Application.put_env(:elixir_claw, :cli_enabled, false)
      Application.put_env(:elixir_claw, :telegram_enabled, false)
      Application.put_env(:elixir_claw, :discord_enabled, false)
      Application.put_env(:elixir_claw, :mcp_servers, [])

      modules =
        ClawApplication.child_specs()
        |> Enum.map(fn spec ->
          spec |> Supervisor.child_spec([]) |> Map.fetch!(:start) |> elem(0)
        end)

       assert modules == [
                ElixirClaw.Repo,
                Registry,
                DynamicSupervisor,
                Phoenix.PubSub.Supervisor,
                Task.Supervisor,
                ElixirClaw.Tools.Registry,
                ElixirClaw.Agent.MemoryGraphIndexer,
                ElixirClaw.Providers.Codex.TokenManager,
                ElixirClaw.Providers.Copilot.TokenManager,
                MCPSupervisor,
                ChannelsSupervisor
              ]
    end
  end

  describe "ElixirClaw.Channels.Supervisor.child_specs/0" do
    test "starts only enabled channels with transient restarts" do
      Application.put_env(:elixir_claw, :channels, %{
        cli: %{name: :application_test_cli, prompt?: false, reader_fun: fn _ -> :eof end},
        telegram: %{bot_token: "123456:test_bot_token"},
        discord: %{name: :application_test_discord}
      })

      Application.put_env(:elixir_claw, :cli_enabled, true)
      Application.put_env(:elixir_claw, :telegram_enabled, true)
      Application.put_env(:elixir_claw, :discord_enabled, true)

      specs = ChannelsSupervisor.child_specs()

      assert Enum.map(specs, fn spec -> elem(spec.start, 0) end) == [
               ElixirClaw.Channels.CLI,
               ElixirClaw.Channels.Telegram,
               ElixirClaw.Channels.Discord
             ]

      assert Enum.all?(specs, &(&1.restart == :transient))
    end

    test "logs and skips misconfigured optional channels" do
      Application.put_env(:elixir_claw, :channels, %{})
      Application.put_env(:elixir_claw, :cli_enabled, false)
      Application.put_env(:elixir_claw, :telegram_enabled, true)
      Application.put_env(:elixir_claw, :discord_enabled, false)

      log =
        capture_log(fn ->
          assert ChannelsSupervisor.child_specs() == []
        end)

      assert log =~ "Skipping Telegram channel startup"
    end
  end

  describe "ElixirClaw.MCP.Supervisor.child_specs/0" do
    test "returns no children when no MCP servers are configured" do
      Application.put_env(:elixir_claw, :mcp_servers, [])

      assert MCPSupervisor.child_specs() == []
    end

    test "builds HTTP and stdio child specs from runtime config" do
      Application.put_env(:elixir_claw, :mcp_servers, [
        %{name: "local-http", url: "http://localhost:4010/mcp", timeout: 5_000},
        %{
          name: "local-stdio",
          command: "npx",
          args: ["-y", "@modelcontextprotocol/server-example"]
        }
      ])

      specs = MCPSupervisor.child_specs()

      assert [http_spec, stdio_spec] = specs

      assert http_spec.start ==
               {ElixirClaw.MCP.HTTPClient, :connect,
                [[timeout: 5_000, url: "http://localhost:4010/mcp"]]}

      assert stdio_spec.start ==
               {ElixirClaw.MCP.StdioClient, :start_link,
                [[command: ["npx", "-y", "@modelcontextprotocol/server-example"]]]}
    end
  end
end
