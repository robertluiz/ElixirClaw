defmodule ElixirClaw.Provider do
  @moduledoc """
  Behaviour defining the contract for all LLM providers.

  Implementations must handle: chat, streaming, token counting, and
  expose their name and supported models.

  💰 `count_tokens/2` is mandatory — callers use it to enforce context
  window budgets before sending requests.
  """

  @type response :: %{
          content: String.t() | nil,
          tool_calls: list() | nil,
          token_usage: map() | nil,
          model: String.t() | nil,
          finish_reason: String.t() | nil
        }

  @doc "Send a list of messages and return the provider response."
  @callback chat(messages :: [map()], opts :: keyword()) :: {:ok, response()} | {:error, term()}

  @doc "Stream a response; returns an Enumerable of chunks."
  @callback stream(messages :: [map()], opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc "Return this provider's identifier string."
  @callback name() :: String.t()

  @doc "Return the list of model identifiers supported by this provider."
  @callback models() :: [String.t()]

  @doc """
  Count tokens for the given text using the specified model.

  💰 Used by ContextBuilder to enforce sliding-window limits before sending.
  """
  @callback count_tokens(text :: String.t(), model :: String.t()) ::
              {:ok, integer()} | {:error, term()}
end
