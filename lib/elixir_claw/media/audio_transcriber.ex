defmodule ElixirClaw.Media.AudioTranscriber do
  @moduledoc false

  @callback transcribe(binary(), keyword()) :: {:ok, String.t()} | {:error, term()}

  defmodule OpenAICompatible do
    @moduledoc false

    @behaviour ElixirClaw.Media.AudioTranscriber

    @default_base_url "https://api.openai.com/v1"
    @default_model "gpt-4o-mini-transcribe"

    @impl true
    def transcribe(audio_binary, opts) when is_binary(audio_binary) and is_list(opts) do
      with {:ok, api_key} <- fetch_required(:api_key),
           {:ok, request_opts} <- request_options(audio_binary, api_key, opts),
           {:ok, response} <- Req.post(request_opts),
           :ok <- validate_response(response),
           {:ok, body} <- decode_body(response.body),
           {:ok, text} <- parse_text(body) do
        {:ok, text}
      else
        {:error, _reason} = error -> error
      end
    end

    defp request_options(audio_binary, api_key, opts) do
      filename = Keyword.get(opts, :filename, infer_filename(opts))
      content_type = Keyword.get(opts, :content_type, infer_content_type(opts))

      {:ok,
       [
         url: transcription_url(),
         auth: {:bearer, api_key},
         form_multipart: transcription_form(audio_binary, filename, content_type, opts)
       ]}
    end

    defp transcription_form(audio_binary, filename, content_type, opts) do
      [
        model: Keyword.get(opts, :model, config() |> Keyword.get(:model, @default_model)),
        response_format: Keyword.get(opts, :response_format, "json"),
        file: {audio_binary, filename: filename, content_type: content_type}
      ]
      |> maybe_put_keyword(:language, Keyword.get(opts, :language))
      |> maybe_put_keyword(:prompt, transcription_prompt(opts))
    end

    defp validate_response(%Req.Response{status: status}) when status in 200..299, do: :ok
    defp validate_response(%Req.Response{status: 401}), do: {:error, :unauthorized}

    defp validate_response(%Req.Response{status: status}) when status >= 500,
      do: {:error, :server_error}

    defp validate_response(%Req.Response{}), do: {:error, :request_failed}

    defp decode_body(body) when is_map(body), do: {:ok, body}

    defp decode_body(body) when is_binary(body) do
      case Jason.decode(body) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, _reason} -> {:error, :invalid_response}
      end
    end

    defp decode_body(_body), do: {:error, :invalid_response}

    defp parse_text(%{"text" => text}) when is_binary(text) and text != "", do: {:ok, text}
    defp parse_text(%{"transcript" => text}) when is_binary(text) and text != "", do: {:ok, text}
    defp parse_text(_body), do: {:error, :invalid_response}

    defp transcription_prompt(opts) do
      [
        Keyword.get(opts, :caption),
        maybe_meta_prompt("duration", Keyword.get(opts, :duration)),
        maybe_meta_prompt("performer", Keyword.get(opts, :performer)),
        maybe_meta_prompt("title", Keyword.get(opts, :title))
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")
      |> case do
        "" -> nil
        prompt -> prompt
      end
    end

    defp infer_filename(opts) do
      case Keyword.get(opts, :title) do
        title when is_binary(title) and title != "" -> "#{title}.ogg"
        _other -> "telegram-audio.ogg"
      end
    end

    defp infer_content_type(opts) do
      if Keyword.get(opts, :performer) == nil and Keyword.get(opts, :title) == nil do
        "audio/ogg"
      else
        "audio/mpeg"
      end
    end

    defp maybe_meta_prompt(_label, nil), do: nil
    defp maybe_meta_prompt(_label, ""), do: nil
    defp maybe_meta_prompt(label, value), do: "#{label}=#{value}"

    defp fetch_required(key) do
      case Keyword.get(config(), key) do
        value when is_binary(value) and value != "" -> {:ok, value}
        _missing -> {:error, :not_configured}
      end
    end

    defp transcription_url do
      config()
      |> Keyword.get(:base_url, @default_base_url)
      |> String.trim_trailing("/")
      |> Kernel.<>("/audio/transcriptions")
    end

    defp config, do: Application.get_env(:elixir_claw, __MODULE__, [])

    defp maybe_put_keyword(keyword, _key, nil), do: keyword
    defp maybe_put_keyword(keyword, _key, ""), do: keyword
    defp maybe_put_keyword(keyword, key, value), do: Keyword.put(keyword, key, value)
  end
end
