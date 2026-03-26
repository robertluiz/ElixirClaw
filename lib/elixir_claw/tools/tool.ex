defmodule ElixirClaw.Tool do
  @moduledoc """
  Behaviour defining the contract for all agent tools.

  🔒 `max_output_bytes/0` and `timeout_ms/0` are mandatory — the ToolRegistry
  uses these to sandbox execution (truncate output, kill on timeout).
  No tool may run unbounded.
  """

  @doc "Return the tool's unique name string (used as key in JSON tool spec)."
  @callback name() :: String.t()

  @doc "Return a human-readable description for the LLM tool schema."
  @callback description() :: String.t()

  @doc "Return the JSON Schema map describing this tool's input parameters."
  @callback parameters_schema() :: map()

  @doc "Execute the tool with validated parameters and optional context map."
  @callback execute(params :: map(), context :: map()) ::
              {:ok, result :: String.t()} | {:error, term()}

  @doc "Optional risk tier used for tool exposure and authorization."
  @callback risk_tier() :: :standard | :privileged

  @doc "Optional logical capability group shown to the orchestrator."
  @callback group() :: String.t()

  @doc """
  Maximum allowed output size in bytes.

  🔒 ToolRegistry truncates results exceeding this value to prevent
  context flooding and unbounded LLM token usage.
  """
  @callback max_output_bytes() :: non_neg_integer()

  @doc """
  Execution timeout in milliseconds.

  🔒 ToolRegistry kills any task exceeding this timeout to prevent
  hung tools from blocking the agent loop.
  """
  @callback timeout_ms() :: non_neg_integer()

  @optional_callbacks risk_tier: 0, group: 0
end
