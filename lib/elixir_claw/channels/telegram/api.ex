defmodule ElixirClaw.Channels.Telegram.API do
  @moduledoc false

  @callback send_message(chat_id :: integer(), text :: String.t()) ::
              {:ok, map()} | {:error, term()}
end
