defmodule Mix.Tasks.Copilot.Login do
  @moduledoc false

  use Mix.Task

  alias ElixirClaw.Providers.Copilot.{OAuth, TokenManager}

  @shortdoc "Starts the GitHub Copilot OAuth device flow"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    device_code_request = oauth_override(:device_code_request, &OAuth.device_code/1)
    device_token_poll = oauth_override(:device_token_poll, &OAuth.poll_device_token/2)
    token_store = oauth_override(:token_store, &TokenManager.persist_token_response/1)
    oauth_opts = Application.get_env(:elixir_claw, OAuth, [])

    with {:ok, device_code} <- device_code_request.(oauth_opts),
         :ok <- print_device_flow_instructions(device_code),
         {:ok, token} <-
           device_token_poll.(
             device_code.device_code,
             Keyword.put_new(oauth_opts, :interval, device_code.interval)
           ),
         :ok <- token_store.(token) do
      Mix.shell().info("GitHub Copilot OAuth token stored.")
    else
      {:error, reason} ->
        Mix.raise("Copilot login failed: #{inspect(reason)}")
    end
  end

  defp print_device_flow_instructions(device_code) do
    Mix.shell().info("Open this URL and enter the code to authorize GitHub Copilot:")
    Mix.shell().info(device_code.verification_uri)
    Mix.shell().info(device_code.user_code)
    Mix.shell().info("Waiting for authorization...")
    :ok
  end

  defp oauth_override(key, default) do
    Application.get_env(:elixir_claw, OAuth, [])
    |> Keyword.get(key, default)
  end
end
