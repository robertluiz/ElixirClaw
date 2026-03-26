defmodule ElixirClaw.Tools.Bootstrap do
  @moduledoc false

  alias ElixirClaw.Tools.Registry
  alias ElixirClaw.Tools.LaunchCodexTui
  alias ElixirClaw.Tools.LaunchOpenCodeTui
  alias ElixirClaw.Tools.ReadInteractiveTerminalOutput
  alias ElixirClaw.Tools.RunTerminalCommand
  alias ElixirClaw.Tools.SendTelegramAudio
  alias ElixirClaw.Tools.SendTelegramPhoto
  alias ElixirClaw.Tools.SendInteractiveTerminalInput
  alias ElixirClaw.Tools.StartInteractiveTerminalSession
  alias ElixirClaw.Tools.StopInteractiveTerminalSession
  alias ElixirClaw.Tools.TaskAgentManager

  def register_builtin_tools(registry \\ Registry) do
    Enum.each(
      [
        TaskAgentManager,
        SendTelegramPhoto,
        SendTelegramAudio,
        RunTerminalCommand,
        LaunchCodexTui,
        LaunchOpenCodeTui,
        StartInteractiveTerminalSession,
        SendInteractiveTerminalInput,
        ReadInteractiveTerminalOutput,
        StopInteractiveTerminalSession
      ],
      &Registry.register(registry, &1)
    )

    :ok
  end
end
