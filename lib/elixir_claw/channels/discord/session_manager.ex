defmodule ElixirClaw.Channels.Discord.SessionManager do
  @moduledoc false

  @callback start_session(map()) :: {:ok, String.t()} | {:error, term()}
  @callback end_session(String.t()) :: :ok | {:error, term()}
end
