defmodule ElixirClaw.Channel do
  @moduledoc """
  Behaviour defining the contract for all input/output channels
  (CLI, Telegram, Discord).

  🔒 `sanitize_input/1` is mandatory — all channel inputs must be
  sanitized before being passed to the agent loop to prevent prompt injection.
  """

  @doc "Start the channel as a linked GenServer."
  @callback start_link(config :: map()) :: GenServer.on_start()

  @doc "Send a message to a user in the given session."
  @callback send_message(channel_pid :: pid(), session_id :: String.t(), content :: String.t()) ::
              :ok | {:error, term()}

  @doc "Parse a raw platform message into an ElixirClaw.Types.Message struct."
  @callback handle_incoming(raw_message :: term()) ::
              {:ok, ElixirClaw.Types.Message.t()} | {:error, term()}

  @doc """
  Sanitize raw user input before passing to the agent loop.

  🔒 Must strip or escape content that could be used for prompt injection.
  Implementations must not return user-controlled content unmodified.
  """
  @callback sanitize_input(raw :: String.t()) :: String.t()
end
