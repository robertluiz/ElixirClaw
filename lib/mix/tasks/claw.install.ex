defmodule Mix.Tasks.Claw.Install do
  @moduledoc false

  use Mix.Task

  @shortdoc "Bootstraps the ElixirClaw workspace"

  @impl true
  def run(_args) do
    case installer_module().run() do
      {:ok, result} ->
        Mix.shell().info("Bootstrap finished.")
        Mix.shell().info("config/config.toml: #{format_status(result.config)}")
        Mix.shell().info(".vscode/tasks.json: #{format_status(result.tasks)}")

        steps =
          result.steps
          |> Enum.map(&Atom.to_string/1)
          |> Enum.join(", ")

        Mix.shell().info("steps: #{steps}")

      {:error, reason} ->
        Mix.raise("Workspace bootstrap failed: #{format_error(reason)}")
    end
  end

  defp installer_module do
    Application.get_env(:elixir_claw, __MODULE__, [])
    |> Keyword.get(:installer, ElixirClaw.Install.Installer)
  end

  defp format_status(:created), do: "created"
  defp format_status(:unchanged), do: "unchanged"
  defp format_status(:preserved), do: "preserved existing file"
  defp format_status(other), do: inspect(other)

  defp format_error({:command_failed, command, args, status, output}) do
    "#{command} #{Enum.join(args, " ")} exited with status #{status}: #{String.trim(output)}"
  end

  defp format_error(reason), do: inspect(reason)
end
