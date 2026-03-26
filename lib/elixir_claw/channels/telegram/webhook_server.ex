defmodule ElixirClaw.Channels.Telegram.WebhookServer do
  @moduledoc false

  def child_spec(opts) do
    case config(opts) do
      {:ok, bandit_opts} ->
        %{
          id: __MODULE__,
          start: {Bandit, :start_link, [bandit_opts]},
          restart: :permanent,
          type: :supervisor
        }

      :disabled ->
        %{id: __MODULE__, start: {__MODULE__, :start_disabled, []}, restart: :temporary}
    end
  end

  def start_disabled, do: :ignore

  def enabled?(opts \\ []) do
    match?({:ok, _opts}, config(opts))
  end

  defp config(opts) do
    telegram_config =
      Application.get_env(:elixir_claw, ElixirClaw.Channels.Telegram, [])
      |> Keyword.merge(opts)

    enabled? = Keyword.get(telegram_config, :webhook_enabled, false)
    public_url = Keyword.get(telegram_config, :webhook_url)
    port = Keyword.get(telegram_config, :webhook_port)

    cond do
      enabled? != true ->
        :disabled

      not (is_binary(public_url) and String.trim(public_url) != "") ->
        :disabled

      not is_integer(port) ->
        :disabled

      true ->
        {:ok,
         [
           plug:
             {ElixirClaw.Channels.Telegram.WebhookRouter,
              [
                secret_token: Keyword.get(telegram_config, :webhook_secret_token),
                telegram_target: ElixirClaw.Channels.Telegram
              ]},
           scheme: :http,
           port: port
         ]}
    end
  end
end
