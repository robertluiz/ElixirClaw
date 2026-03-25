defmodule ElixirClaw.Tools.Bootstrap do
  @moduledoc false

  alias ElixirClaw.Tools.Registry
  alias ElixirClaw.Tools.TaskAgentManager

  def register_builtin_tools(registry \\ Registry) do
    Enum.each([TaskAgentManager], &Registry.register(registry, &1))
    :ok
  end
end
