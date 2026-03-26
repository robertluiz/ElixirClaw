defmodule ElixirClaw.Tools.TelegramMediaTest do
  use ExUnit.Case, async: false

  alias ElixirClaw.Bus.MessageBus
  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.Message, as: MessageSchema
  alias ElixirClaw.Schema.Session, as: SessionSchema
  alias ElixirClaw.Session.Manager
  alias ElixirClaw.Tools.{SendTelegramAudio, SendTelegramPhoto}

  setup do
    Repo.reset!()
    Repo.delete_all(MessageSchema)
    Repo.delete_all(SessionSchema)
    kill_session_processes()

    on_exit(fn -> kill_session_processes() end)

    :ok
  end

  test "send_telegram_photo publishes a photo payload for the current telegram session" do
    assert {:ok, session_id} = Manager.start_session(base_attrs())
    assert :ok = MessageBus.subscribe(topic(session_id))

    assert {:ok, result} =
             SendTelegramPhoto.execute(
               %{"url" => "https://example.com/demo.png", "caption" => "preview"},
               %{"session_id" => session_id, "channel" => "telegram"}
             )

    assert result =~ "Queued Telegram photo"

    assert_receive %{
      type: :outgoing_message,
      session_id: ^session_id,
      content: %{type: :photo, url: "https://example.com/demo.png", caption: "preview"}
    }
  end

  test "send_telegram_audio publishes an audio payload with optional metadata" do
    assert {:ok, session_id} = Manager.start_session(base_attrs())
    assert :ok = MessageBus.subscribe(topic(session_id))

    assert {:ok, result} =
             SendTelegramAudio.execute(
               %{
                 "url" => "https://example.com/demo.mp3",
                 "caption" => "voice note",
                 "duration" => 17,
                 "performer" => "ElixirClaw",
                 "title" => "Daily brief"
               },
               %{"session_id" => session_id, "channel" => "telegram"}
             )

    assert result =~ "Queued Telegram audio"

    assert_receive %{
      type: :outgoing_message,
      session_id: ^session_id,
      content: %{
        type: :audio,
        url: "https://example.com/demo.mp3",
        caption: "voice note",
        duration: 17,
        performer: "ElixirClaw",
        title: "Daily brief"
      }
    }
  end

  test "telegram media tools reject non-telegram channels" do
    assert {:ok, session_id} = Manager.start_session(base_attrs(channel: "cli"))

    assert {:error, :unsupported_channel} =
             SendTelegramPhoto.execute(
               %{"url" => "https://example.com/demo.png"},
               %{"session_id" => session_id, "channel" => "cli"}
             )
  end

  test "telegram media tools reject non-http urls" do
    assert {:ok, session_id} = Manager.start_session(base_attrs())

    assert {:error, :invalid_params} =
             SendTelegramAudio.execute(
               %{"url" => "C:/temp/audio.mp3"},
               %{"session_id" => session_id, "channel" => "telegram"}
             )
  end

  defp base_attrs(overrides \\ %{}) do
    overrides = Enum.into(overrides, %{})

    Map.merge(
      %{
        channel: "telegram",
        channel_user_id: "telegram-user-#{System.unique_integer([:positive])}",
        provider: "openai",
        model: "gpt-4o-mini",
        metadata: %{"chat_id" => 99}
      },
      overrides
    )
  end

  defp topic(session_id), do: "session:#{session_id}"

  defp kill_session_processes do
    for pid <- Registry.select(ElixirClaw.SessionRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}]) do
      _ = DynamicSupervisor.terminate_child(ElixirClaw.SessionSupervisor, pid)
    end
  catch
    :exit, _reason -> :ok
  end
end
