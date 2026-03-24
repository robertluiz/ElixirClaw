defmodule ElixirClaw.Channels.Discord.AgentLoop do
  @moduledoc false

  @callback process_message(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
end
