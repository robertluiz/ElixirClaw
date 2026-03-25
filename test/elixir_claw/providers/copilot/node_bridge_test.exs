defmodule ElixirClaw.Providers.Copilot.NodeBridgeTest do
  use ExUnit.Case, async: true

  alias ElixirClaw.Providers.Copilot.NodeBridge

  test "bridge_script_path/0 resolves to the app priv directory" do
    expected_path =
      Path.join([
        :elixir_claw |> :code.priv_dir() |> to_string(),
        "copilot_bridge",
        "index.mjs"
      ])
      |> Path.expand()

    assert NodeBridge.bridge_script_path() == expected_path
    assert File.exists?(expected_path)
  end

  test "bridge_cwd/0 resolves to the bridge directory" do
    expected_cwd =
      :elixir_claw
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("copilot_bridge")
      |> Path.expand()

    assert NodeBridge.bridge_cwd() == expected_cwd
    assert File.dir?(expected_cwd)
  end
end
