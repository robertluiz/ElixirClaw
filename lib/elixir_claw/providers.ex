defmodule ElixirClaw.Providers do
  @moduledoc false

  alias ElixirClaw.Providers.{Anthropic, CopilotBYOK, OpenAI, OpenRouter}
  alias ElixirClaw.Providers.Copilot.Client, as: CopilotClient
  alias ElixirClaw.Providers.Codex.Client, as: CodexClient

  @provider_modules %{
    "anthropic" => Anthropic,
    "codex" => CodexClient,
    "copilot" => CopilotClient,
    "copilot_byok" => CopilotBYOK,
    "github_copilot" => CopilotClient,
    "openai" => OpenAI,
    "openrouter" => OpenRouter
  }

  @spec resolve(module() | String.t() | nil) :: {:ok, module()} | {:error, :unknown_provider}
  def resolve(provider) when is_atom(provider), do: {:ok, provider}

  def resolve(provider) when is_binary(provider) do
    provider = String.trim(provider)

    @provider_modules
    |> Map.get(provider)
    |> case do
      module when is_atom(module) -> {:ok, module}
      nil -> {:error, :unknown_provider}
    end
  end

  def resolve(_provider), do: {:error, :unknown_provider}
end
