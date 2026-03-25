defmodule ElixirClaw.Install.InstallerTest do
  use ExUnit.Case, async: true

  alias ElixirClaw.Install.Installer

  test "plan/0 returns the bootstrap steps in execution order" do
    assert [
             %{id: :npm_install, kind: :system, args: ["install"]},
             %{id: :cozo_rebuild, kind: :system, args: ["rebuild", "cozo-node"]},
             %{id: :mix_deps_get, kind: :mix, task: "deps.get"},
             %{id: :mix_compile, kind: :mix, task: "compile"}
           ] = Installer.plan()
  end

  test "workspace_tasks_json/0 matches the checked-in VS Code tasks file" do
    tasks_path = Path.expand("../../../.vscode/tasks.json", __DIR__)

    assert File.read!(tasks_path) == Installer.workspace_tasks_json()
  end

  test "run/1 creates missing bootstrap files and executes every install step" do
    workspace_root = make_workspace!()

    File.write!(
      Path.join(workspace_root, "elixir_claw.example.toml"),
      "database_path = \"test.db\"\n"
    )

    command_runner = fn root, command, args ->
      send(self(), {:command, root, Path.basename(command), args})
      :ok
    end

    mix_runner = fn task, args ->
      send(self(), {:mix_task, task, args})
      :ok
    end

    assert {:ok, %{config: :created, tasks: :created}} =
             Installer.run(
               workspace_root: workspace_root,
               command_runner: command_runner,
               mix_runner: mix_runner
             )

    assert File.exists?(Path.join(workspace_root, "config/config.toml"))

    assert File.read!(Path.join(workspace_root, ".vscode/tasks.json")) ==
             Installer.workspace_tasks_json()

    assert_received {:command, ^workspace_root, npm_command, ["install"]}
    assert npm_command in ["npm", "npm.cmd"]
    assert_received {:command, ^workspace_root, ^npm_command, ["rebuild", "cozo-node"]}
    assert_received {:mix_task, "deps.get", []}
    assert_received {:mix_task, "compile", []}
  end

  test "run/1 preserves existing config and custom VS Code tasks" do
    workspace_root = make_workspace!()

    File.write!(
      Path.join(workspace_root, "elixir_claw.example.toml"),
      "database_path = \"test.db\"\n"
    )

    config_path = Path.join(workspace_root, "config/config.toml")
    tasks_path = Path.join(workspace_root, ".vscode/tasks.json")

    File.mkdir_p!(Path.dirname(config_path))
    File.mkdir_p!(Path.dirname(tasks_path))
    File.write!(config_path, "existing = true\n")
    File.write!(tasks_path, "{\n  \"version\": \"2.0.0\",\n  \"tasks\": []\n}\n")

    assert {:ok, %{config: :unchanged, tasks: :preserved}} =
             Installer.run(
               workspace_root: workspace_root,
               command_runner: fn _root, _command, _args -> :ok end,
               mix_runner: fn _task, _args -> :ok end
             )

    assert File.read!(config_path) == "existing = true\n"
    assert File.read!(tasks_path) == "{\n  \"version\": \"2.0.0\",\n  \"tasks\": []\n}\n"
  end

  @tag :tmp_dir
  test "run/1 executes Windows npm.cmd scripts through cmd.exe when using the default runner" do
    if match?({:win32, _}, :os.type()) do
      workspace_root = make_workspace!()
      npm_root = Path.join(workspace_root, "fake_node")
      npm_cmd = Path.join(npm_root, "npm.cmd")
      output_path = Path.join(workspace_root, "npm-output.txt")

      File.mkdir_p!(npm_root)

      File.write!(
        Path.join(workspace_root, "elixir_claw.example.toml"),
        "database_path = \"test.db\"\n"
      )

      File.write!(
        npm_cmd,
        [
          "@echo off\r\n",
          "setlocal\r\n",
          "echo %~1 %~2>>\"",
          output_path,
          "\"\r\n"
        ]
      )

      original_path = System.get_env("PATH")

      on_exit(fn ->
        if is_nil(original_path) do
          System.delete_env("PATH")
        else
          System.put_env("PATH", original_path)
        end
      end)

      System.put_env("PATH", npm_root <> ";" <> (original_path || ""))

      assert {:ok, %{config: :created, tasks: :created}} =
               Installer.run(
                 workspace_root: workspace_root,
                 mix_runner: fn _task, _args -> :ok end
               )

      assert File.read!(output_path) == "install \r\nrebuild cozo-node\r\n"
    else
      assert true
    end
  end

  defp make_workspace! do
    path =
      Path.join(System.tmp_dir!(), "elixir_claw_installer_#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
