defmodule ElixirClaw.Channels.Discord.API do
  @moduledoc false

  @callback create_message(channel_id :: integer(), content :: String.t()) ::
              {:ok, map()} | {:error, term()}
end
