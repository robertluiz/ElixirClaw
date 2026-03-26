defmodule ElixirClaw.Media.AudioTranscriberTest do
  use ExUnit.Case, async: false

  alias ElixirClaw.Media.AudioTranscriber.OpenAICompatible

  setup do
    previous_config = Application.get_env(:elixir_claw, OpenAICompatible)

    on_exit(fn ->
      if is_nil(previous_config),
        do: Application.delete_env(:elixir_claw, OpenAICompatible),
        else: Application.put_env(:elixir_claw, OpenAICompatible, previous_config)
    end)

    :ok
  end

  test "returns not_configured when api_key is missing" do
    Application.delete_env(:elixir_claw, OpenAICompatible)

    assert {:error, :not_configured} = OpenAICompatible.transcribe("audio-binary", [])
  end

  test "posts multipart transcription requests and returns text" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/v1/audio/transcriptions", fn conn ->
      assert ["multipart/form-data;" <> _rest] = Plug.Conn.get_req_header(conn, "content-type")
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "name=\"model\""
      assert body =~ "gpt-4o-mini-transcribe"
      assert body =~ "name=\"response_format\""
      assert body =~ "name=\"prompt\""
      assert body =~ "caption text"
      assert body =~ "name=\"file\""
      assert body =~ "audio-binary"

      Plug.Conn.resp(conn, 200, ~s({"text":"transcribed from api"}))
    end)

    Application.put_env(:elixir_claw, OpenAICompatible,
      api_key: "test-key",
      base_url: "http://localhost:#{bypass.port}/v1"
    )

    assert {:ok, "transcribed from api"} =
             OpenAICompatible.transcribe("audio-binary",
               caption: "caption text",
               duration: 12,
               performer: "Claw",
               title: "Brief"
             )
  end
end
