defmodule Mix.Tasks.Codex.Login do
  @moduledoc false

  use Mix.Task

  alias ElixirClaw.Providers.Codex.{OAuth, TokenManager}

  @shortdoc "Starts the Codex OAuth login flow"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    pkce = OAuth.generate_pkce()
    auth_url = OAuth.auth_url(code_challenge: pkce.challenge)

    Mix.shell().info("Open this URL to authorize Codex:")
    Mix.shell().info(auth_url)

    code =
      Mix.shell()
      |> then(& &1.prompt("Paste the authorization code: "))
      |> to_string()
      |> String.trim()

    token_exchange = oauth_override(:auth_code_exchange, &OAuth.exchange_code/3)
    token_store = oauth_override(:token_store, &TokenManager.persist_token_response/1)
    oauth_opts = Application.get_env(:elixir_claw, OAuth, [])

    case token_exchange.(code, pkce.verifier, oauth_opts) do
      {:ok, token} ->
        :ok = token_store.(token)
        Mix.shell().info("Codex OAuth token stored.")

      {:error, reason} ->
        Mix.raise("Codex login failed: #{inspect(reason)}")
    end
  end

  defp oauth_override(key, default) do
    Application.get_env(:elixir_claw, OAuth, [])
    |> Keyword.get(key, default)
  end
end
