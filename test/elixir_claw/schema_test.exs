defmodule ElixirClaw.SchemaTest do
  use ExUnit.Case, async: false

  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.Message
  alias ElixirClaw.Schema.Session

  setup_all do
    Repo.reset!()
    :ok
  end

  setup do
    Repo.delete_all(Message)
    Repo.delete_all(Session)

    :ok
  end

  test "create session with valid attrs" do
    attrs = %{
      channel: "telegram",
      channel_user_id: "user-123",
      provider: "openai",
      model: "gpt-4o-mini",
      metadata: %{"locale" => "en"}
    }

    assert {:ok, %Session{} = session} =
             %Session{}
             |> Session.changeset(attrs)
             |> Repo.insert()

    assert is_binary(session.id)
    assert session.channel == "telegram"
    assert session.channel_user_id == "user-123"
    assert session.provider == "openai"
    assert session.token_count_in == 0
    assert session.token_count_out == 0
    assert session.metadata == %{"locale" => "en"}
  end

  test "session requires channel, channel_user_id, provider" do
    changeset = Session.changeset(%Session{}, %{})

    refute changeset.valid?

    assert errors_on(changeset) == %{
             channel: ["can't be blank"],
             channel_user_id: ["can't be blank"],
             provider: ["can't be blank"]
           }
  end

  test "create message linked to session" do
    session = session_fixture()

    attrs = %{
      session_id: session.id,
      role: "assistant",
      content: "Hello from the assistant",
      token_count: 42,
      tool_call_id: "tool-1",
      tool_calls: %{"name" => "search"}
    }

    assert {:ok, %Message{} = message} =
             %Message{}
             |> Message.changeset(attrs)
             |> Repo.insert()

    assert message.session_id == session.id
    assert message.role == "assistant"
    assert message.content == "Hello from the assistant"
    assert message.token_count == 42
    assert message.tool_call_id == "tool-1"
    assert message.tool_calls == %{"name" => "search"}
    assert message.inserted_at
  end

  test "message requires valid role" do
    session = session_fixture()

    changeset =
      Message.changeset(%Message{}, %{
        session_id: session.id,
        role: "invalid",
        content: "bad role"
      })

    refute changeset.valid?
    assert %{role: ["is invalid"]} = errors_on(changeset)
  end

  test "query messages by session_id" do
    session = session_fixture(%{channel_user_id: "user-a"})
    other_session = session_fixture(%{channel_user_id: "user-b"})

    message_1 = message_fixture(session, %{content: "first"})
    message_2 = message_fixture(session, %{content: "second"})
    _other_message = message_fixture(other_session, %{content: "third"})

    messages =
      Repo.list_session_messages(session.id)

    assert Enum.map(messages, & &1.id) == [message_1.id, message_2.id]
    assert Enum.map(messages, & &1.content) == ["first", "second"]
  end

  test "token counts tracked on session" do
    session = session_fixture()

    assert {:ok, updated_session} =
             session
             |> Session.changeset(%{token_count_in: 150, token_count_out: 275})
             |> Repo.update()

    reloaded_session = Repo.get!(Session, session.id)

    assert updated_session.token_count_in == 150
    assert updated_session.token_count_out == 275
    assert reloaded_session.token_count_in == 150
    assert reloaded_session.token_count_out == 275
  end

  test "deleting session cascades to messages" do
    session = session_fixture()
    message = message_fixture(session)

    assert {:ok, _session} = Repo.delete(session)
    refute Repo.get(Session, session.id)
    refute Repo.get(Message, message.id)
  end

  defp session_fixture(attrs \\ %{}) do
    valid_attrs = %{
      channel: "telegram",
      channel_user_id: "fixture-user-#{System.unique_integer([:positive])}",
      provider: "openai",
      model: "gpt-4o-mini"
    }

    attrs = Map.merge(valid_attrs, attrs)

    {:ok, session} =
      %Session{}
      |> Session.changeset(attrs)
      |> Repo.insert()

    session
  end

  defp message_fixture(session, attrs \\ %{}) do
    valid_attrs = %{
      session_id: session.id,
      role: "user",
      content: "fixture message",
      token_count: 12
    }

    attrs = Map.merge(valid_attrs, attrs)

    {:ok, message} =
      %Message{}
      |> Message.changeset(attrs)
      |> Repo.insert()

    message
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r/%{(\w+)}/, message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
