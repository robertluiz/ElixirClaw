defmodule ElixirClaw.Install.Installer do
  @moduledoc false

  @config_template_path "elixir_claw.example.toml"
  @config_target_path Path.join("config", "config.toml")
  @workspace_tasks_template_path Path.expand("../../../.vscode/tasks.json", __DIR__)
  @workspace_tasks_path Path.join(".vscode", "tasks.json")

  @type install_step :: %{
          id: atom(),
          kind: :mix | :system,
          label: String.t(),
          args: [String.t()],
          command: String.t() | nil,
          task: String.t() | nil
        }

  @spec plan() :: [install_step()]
  def plan do
    npm_command = npm_command()

    [
      %{
        id: :npm_install,
        kind: :system,
        label: "Install Node dependencies",
        command: npm_command,
        task: nil,
        args: ["install"]
      },
      %{
        id: :copilot_bridge_npm_install,
        kind: :system,
        label: "Install GitHub Copilot bridge dependencies",
        command: npm_command,
        task: nil,
        args: ["install", "--prefix", "priv/copilot_bridge"]
      },
      %{
        id: :cozo_rebuild,
        kind: :system,
        label: "Rebuild the Cozo native bridge",
        command: npm_command,
        task: nil,
        args: ["rebuild", "cozo-node"]
      },
      %{
        id: :mix_deps_get,
        kind: :mix,
        label: "Install Elixir dependencies",
        command: nil,
        task: "deps.get",
        args: []
      },
      %{
        id: :mix_compile,
        kind: :mix,
        label: "Compile the project",
        command: nil,
        task: "compile",
        args: []
      }
    ]
  end

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    workspace_root = Keyword.get(opts, :workspace_root, File.cwd!())
    file_ops = file_ops(opts)
    command_runner = Keyword.get(opts, :command_runner, &default_command_runner/3)
    mix_runner = Keyword.get(opts, :mix_runner, &default_mix_runner/2)

    with {:ok, config_status} <- ensure_default_config(workspace_root, file_ops),
         :ok <- run_install_steps(workspace_root, command_runner, mix_runner, plan()),
         {:ok, tasks_status} <- ensure_workspace_tasks(workspace_root, file_ops) do
      {:ok, %{config: config_status, tasks: tasks_status, steps: Enum.map(plan(), & &1.id)}}
    end
  end

  @spec workspace_tasks() :: map()
  def workspace_tasks do
    %{
      "version" => "2.0.0",
      "tasks" => [
        shell_task("Bootstrap workspace", "mix", ["setup"], %{"group" => "build"}),
        shell_task("Compile project", "mix", ["compile"], %{"group" => "build"}),
        shell_task("Run test suite", "mix", ["test"], %{"group" => "test"}),
        shell_task("Run ElixirClaw", "mix", ["run", "--no-halt"], %{"isBackground" => true}),
        shell_task("Login Codex", "mix", ["codex.login"]),
        shell_task("Login GitHub Copilot", "mix", ["copilot.login"])
      ]
    }
  end

  @spec workspace_tasks_json() :: String.t()
  def workspace_tasks_json do
    case File.read(@workspace_tasks_template_path) do
      {:ok, template} -> template
      {:error, _reason} -> Jason.encode!(workspace_tasks(), pretty: true) <> "\n"
    end
  end

  defp run_install_steps(workspace_root, command_runner, mix_runner, steps) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case run_step(step, workspace_root, command_runner, mix_runner) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp run_step(
         %{kind: :system, command: command, args: args},
         workspace_root,
         command_runner,
         _mix_runner
       ) do
    command_runner.(workspace_root, command, args)
  end

  defp run_step(
         %{kind: :mix, task: task, args: args},
         _workspace_root,
         _command_runner,
         mix_runner
       ) do
    mix_runner.(task, args)
  end

  defp ensure_default_config(workspace_root, file_ops) do
    config_target = Path.join(workspace_root, @config_target_path)

    if file_ops.exists?.(config_target) do
      {:ok, :unchanged}
    else
      config_template = Path.join(workspace_root, @config_template_path)

      with :ok <- file_ops.mkdir_p.(Path.dirname(config_target)),
           :ok <- file_ops.copy.(config_template, config_target) do
        {:ok, :created}
      end
    end
  end

  defp ensure_workspace_tasks(workspace_root, file_ops) do
    tasks_path = Path.join(workspace_root, @workspace_tasks_path)
    expected_content = workspace_tasks_json()

    cond do
      not file_ops.exists?.(tasks_path) ->
        with :ok <- file_ops.mkdir_p.(Path.dirname(tasks_path)),
             :ok <- file_ops.write.(tasks_path, expected_content) do
          {:ok, :created}
        end

      true ->
        case file_ops.read.(tasks_path) do
          {:ok, ^expected_content} -> {:ok, :unchanged}
          {:ok, _different_content} -> {:ok, :preserved}
          {:error, _reason} = error -> error
        end
    end
  end

  defp shell_task(label, command, args, extra \\ %{}) do
    Map.merge(
      %{
        "label" => label,
        "type" => "shell",
        "command" => command,
        "args" => args,
        "problemMatcher" => []
      },
      extra
    )
  end

  defp file_ops(opts) do
    %{
      exists?: Keyword.get(opts, :file_exists?, &File.exists?/1),
      mkdir_p: Keyword.get(opts, :mkdir_p, &File.mkdir_p/1),
      copy: Keyword.get(opts, :copy_file, &File.cp/2),
      read: Keyword.get(opts, :read_file, &File.read/1),
      write: Keyword.get(opts, :write_file, &File.write/2)
    }
  end

  defp default_command_runner(workspace_root, command, args) do
    {system_command, system_args} = system_command(command, args)

    case System.cmd(system_command, system_args, cd: workspace_root, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:command_failed, command, args, status, output}}
    end
  end

  defp default_mix_runner(task, args) do
    Mix.Task.reenable(task)
    Mix.Task.run(task, args)
    :ok
  end

  defp npm_command do
    System.find_executable("npm") || System.find_executable("npm.cmd") || "npm"
  end

  defp system_command(command, args) do
    if windows_shell_script?(command) do
      {System.get_env("COMSPEC") || "cmd", ["/c", command | args]}
    else
      {command, args}
    end
  end

  defp windows_shell_script?(command) do
    extension = command |> Path.extname() |> String.downcase()

    match?({:win32, _}, :os.type()) and File.regular?(command) and extension in [".cmd", ".bat"]
  end
end
