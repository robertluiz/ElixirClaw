defmodule ElixirClaw.Tools.TelegramMedia do
  @moduledoc false

  alias ElixirClaw.Bus.MessageBus
  alias ElixirClaw.Session.Manager

  @spec publish_photo(map(), map()) :: {:ok, map()} | {:error, term()}
  def publish_photo(params, context) when is_map(params) and is_map(context) do
    with {:ok, session_id} <- fetch_session_id(context),
         :ok <- ensure_telegram_channel(context),
         :ok <- ensure_session_exists(session_id),
         {:ok, payload} <- build_photo_payload(params),
         :ok <- publish_payload(session_id, payload) do
      {:ok, payload}
    end
  end

  @spec publish_audio(map(), map()) :: {:ok, map()} | {:error, term()}
  def publish_audio(params, context) when is_map(params) and is_map(context) do
    with {:ok, session_id} <- fetch_session_id(context),
         :ok <- ensure_telegram_channel(context),
         :ok <- ensure_session_exists(session_id),
         {:ok, payload} <- build_audio_payload(params),
         :ok <- publish_payload(session_id, payload) do
      {:ok, payload}
    end
  end

  def photo_schema do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{
          "type" => "string",
          "description" => "Public HTTP(S) image URL for the Telegram chat."
        },
        "caption" => %{
          "type" => "string",
          "description" => "Optional caption shown below the image."
        }
      },
      "required" => ["url"]
    }
  end

  def audio_schema do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{
          "type" => "string",
          "description" => "Public HTTP(S) audio URL for the Telegram chat."
        },
        "caption" => %{
          "type" => "string",
          "description" => "Optional caption shown with the audio."
        },
        "duration" => %{
          "type" => "integer",
          "minimum" => 0,
          "description" => "Optional duration in seconds."
        },
        "performer" => %{"type" => "string", "description" => "Optional performer metadata."},
        "title" => %{"type" => "string", "description" => "Optional audio title metadata."}
      },
      "required" => ["url"]
    }
  end

  def format_photo_result(payload) do
    "Queued Telegram photo #{payload.url}" <> maybe_suffix(payload[:caption], " with caption")
  end

  def format_audio_result(payload) do
    "Queued Telegram audio #{payload.url}"
    |> maybe_append(payload[:caption], " with caption")
    |> maybe_append(payload[:duration], " (duration: #{payload[:duration]}s)")
  end

  defp maybe_suffix(nil, _suffix), do: ""
  defp maybe_suffix("", _suffix), do: ""
  defp maybe_suffix(_value, suffix), do: suffix

  defp maybe_append(text, nil, _suffix), do: text
  defp maybe_append(text, "", _suffix), do: text
  defp maybe_append(text, _value, suffix), do: text <> suffix

  defp fetch_session_id(context) do
    case Map.get(context, "session_id", Map.get(context, :session_id)) do
      session_id when is_binary(session_id) and session_id != "" -> {:ok, session_id}
      _missing -> {:error, :invalid_context}
    end
  end

  defp ensure_telegram_channel(context) do
    case Map.get(context, "channel", Map.get(context, :channel)) do
      "telegram" -> :ok
      _other -> {:error, :unsupported_channel}
    end
  end

  defp ensure_session_exists(session_id) do
    case Manager.get_session(session_id) do
      {:ok, _session} -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp build_photo_payload(params) do
    with {:ok, url} <- fetch_url(params) do
      {:ok,
       %{type: :photo, url: url}
       |> maybe_put_string(:caption, params)}
    end
  end

  defp build_audio_payload(params) do
    with {:ok, url} <- fetch_url(params) do
      {:ok,
       %{type: :audio, url: url}
       |> maybe_put_string(:caption, params)
       |> maybe_put_integer(:duration, params)
       |> maybe_put_string(:performer, params)
       |> maybe_put_string(:title, params)}
    end
  end

  defp fetch_url(params) do
    case Map.get(params, "url", Map.get(params, :url)) do
      url when is_binary(url) and url != "" -> validate_url(url)
      _missing -> {:error, :invalid_params}
    end
  end

  defp validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, url}

      _invalid ->
        {:error, :invalid_params}
    end
  end

  defp maybe_put_string(payload, key, params) do
    case Map.get(params, Atom.to_string(key), Map.get(params, key)) do
      value when is_binary(value) and value != "" -> Map.put(payload, key, value)
      _other -> payload
    end
  end

  defp maybe_put_integer(payload, key, params) do
    case Map.get(params, Atom.to_string(key), Map.get(params, key)) do
      value when is_integer(value) and value >= 0 -> Map.put(payload, key, value)
      _other -> payload
    end
  end

  defp publish_payload(session_id, payload) do
    MessageBus.publish(topic(session_id), %{
      type: :outgoing_message,
      session_id: session_id,
      content: payload
    })
  end

  defp topic(session_id), do: "session:#{session_id}"
end

defmodule ElixirClaw.Tools.SendTelegramPhoto do
  @moduledoc false

  @behaviour ElixirClaw.Tool

  alias ElixirClaw.Tools.TelegramMedia

  @impl true
  def name, do: "send_telegram_photo"

  @impl true
  def description do
    "Send an image to the current Telegram chat using a public image URL. Use this when the user needs a generated or referenced image delivered directly in Telegram."
  end

  @impl true
  def parameters_schema, do: TelegramMedia.photo_schema()

  @impl true
  def execute(params, context) do
    with {:ok, payload} <- TelegramMedia.publish_photo(params, context) do
      {:ok, TelegramMedia.format_photo_result(payload)}
    end
  end

  @impl true
  def max_output_bytes, do: 1_024

  @impl true
  def timeout_ms, do: 1_000
end

defmodule ElixirClaw.Tools.SendTelegramAudio do
  @moduledoc false

  @behaviour ElixirClaw.Tool

  alias ElixirClaw.Tools.TelegramMedia

  @impl true
  def name, do: "send_telegram_audio"

  @impl true
  def description do
    "Send an audio file to the current Telegram chat using a public audio URL, with optional caption and metadata."
  end

  @impl true
  def parameters_schema, do: TelegramMedia.audio_schema()

  @impl true
  def execute(params, context) do
    with {:ok, payload} <- TelegramMedia.publish_audio(params, context) do
      {:ok, TelegramMedia.format_audio_result(payload)}
    end
  end

  @impl true
  def max_output_bytes, do: 1_024

  @impl true
  def timeout_ms, do: 1_000
end
