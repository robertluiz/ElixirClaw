defmodule Mix.Tasks.Claw.InstallTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defmodule TestInstaller do
    def run do
      send(self(), :installer_invoked)
      {:ok, %{config: :created, tasks: :preserved, steps: [:npm_install, :mix_compile]}}
    end
  end

  defmodule FailingInstaller do
    def run do
      {:error, {:command_failed, "npm.cmd", ["install"], 1, "boom"}}
    end
  end

  setup do
    Mix.Task.clear()

    previous = Application.get_env(:elixir_claw, Mix.Tasks.Claw.Install)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:elixir_claw, Mix.Tasks.Claw.Install)
      else
        Application.put_env(:elixir_claw, Mix.Tasks.Claw.Install, previous)
      end
    end)

    :ok
  end

  test "run/1 reports the bootstrap result" do
    Application.put_env(:elixir_claw, Mix.Tasks.Claw.Install, installer: TestInstaller)

    output =
      capture_io(fn ->
        Mix.Tasks.Claw.Install.run([])
      end)

    assert_receive :installer_invoked
    assert output =~ "Bootstrap finished."
    assert output =~ "config/config.toml: created"
    assert output =~ ".vscode/tasks.json: preserved existing file"
    assert output =~ "steps: npm_install, mix_compile"
  end

  test "run/1 raises when the installer fails" do
    Application.put_env(:elixir_claw, Mix.Tasks.Claw.Install, installer: FailingInstaller)

    assert_raise Mix.Error, ~r/Workspace bootstrap failed/, fn ->
      capture_io(fn ->
        Mix.Tasks.Claw.Install.run([])
      end)
    end
  end
end
