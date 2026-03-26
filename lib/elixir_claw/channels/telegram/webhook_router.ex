defmodule ElixirClaw.Channels.Telegram.WebhookRouter do
  @moduledoc false

  use Plug.Router

  import Plug.Conn

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  def init(opts), do: opts

  def call(conn, opts) do
    conn
    |> assign(:telegram_webhook_secret_token, Keyword.get(opts, :secret_token))
    |> assign(
      :telegram_webhook_target,
      Keyword.get(opts, :telegram_target, ElixirClaw.Channels.Telegram)
    )
    |> super(opts)
  end

  post "/telegram/webhook" do
    case validate_secret_token(conn) do
      :ok ->
        case conn.body_params do
          %{} = update ->
            case deliver_update(conn.assigns.telegram_webhook_target, update) do
              :ok -> send_resp(conn, 200, "OK")
              {:error, _reason} -> send_resp(conn, 500, "update delivery failed")
            end

          _other ->
            send_resp(conn, 400, "invalid update")
        end

      {:error, status} ->
        send_resp(conn, status, "unauthorized")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp validate_secret_token(conn) do
    expected = conn.assigns[:telegram_webhook_secret_token]

    case expected do
      token when is_binary(token) and token != "" ->
        provided =
          conn
          |> get_req_header("x-telegram-bot-api-secret-token")
          |> List.first()

        if is_binary(provided) and Plug.Crypto.secure_compare(provided, token) do
          :ok
        else
          {:error, 401}
        end

      _other ->
        :ok
    end
  end

  defp deliver_update(target, update) do
    GenServer.call(target, {:process_update, update}, 5_000)
    :ok
  catch
    :exit, reason -> {:error, reason}
  end
end
