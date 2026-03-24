defmodule ElixirClaw.Agent.MemoryTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Mox

  alias ElixirClaw.Agent.ContextBuilder
  alias ElixirClaw.Agent.Memory
  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.Message
  alias ElixirClaw.Schema.Session
  alias ElixirClaw.Test.Factory
  alias ElixirClaw.Types.ProviderResponse

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup_all do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    create_test_tables!()

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end)

    :ok
  end

  setup do
    Repo.delete_all(Message)
    Repo.delete_all(Session)

    previous_config = Application.get_env(:elixir_claw, Memory)

    on_exit(fn ->
      restore_memory_config(previous_config)
    end)

    :ok
  end

  describe "consolidation_needed?/2" do
    test "returns false when total message tokens stay below the default threshold" do
      session = Factory.insert_session!()

      Factory.insert_message!(
        session_id: session.id,
        role: "user",
        content: String.duplicate("a", 9_828),
        token_count: 2_457
      )

      refute Memory.consolidation_needed?(session.id, [])
    end

    test "returns true when total message tokens exceed the configured threshold" do
      session = Factory.insert_session!()

      Factory.insert_message!(session_id: session.id, role: "user", content: String.duplicate("a", 16), token_count: 4)
      Factory.insert_message!(session_id: session.id, role: "assistant", content: String.duplicate("b", 12), token_count: 3)

      assert Memory.consolidation_needed?(session.id, threshold: 6)
    end

    test "uses application config threshold when opts omit one" do
      session = Factory.insert_session!()

      Application.put_env(:elixir_claw, Memory, threshold: 5)

      Factory.insert_message!(session_id: session.id, role: "user", content: String.duplicate("a", 24), token_count: 6)

      assert Memory.consolidation_needed?(session.id, [])
    end
  end

  describe "consolidate/2" do
    test "returns :not_needed when the session stays under the threshold" do
      session = Factory.insert_session!()
      Factory.insert_message!(session_id: session.id, role: "user", content: "short", token_count: 1)

      assert {:ok, :not_needed} = Memory.consolidate(session.id, ElixirClaw.MockProvider)

      assert [%Message{role: "user", content: "short"}] = persisted_messages(session.id)
    end

    test "summarizes the conversation, deletes old messages, and inserts a system summary" do
      session = Factory.insert_session!()

      first = Factory.insert_message!(session_id: session.id, role: "user", content: "Hello there", token_count: 20)
      second = Factory.insert_message!(session_id: session.id, role: "assistant", content: "General Kenobi", token_count: 20)

      summary = "User greeted the assistant and received a Star Wars reply."

      expect(ElixirClaw.MockProvider, :chat, fn messages, opts ->
        assert opts == []

        assert [
                 %{
                   role: "user",
                   content:
                     "Summarize this conversation:\nuser: Hello there\nassistant: General Kenobi"
                 }
               ] = messages

        {:ok, %ProviderResponse{content: summary}}
      end)

      assert {:ok, %{summary: ^summary, messages_archived: 2}} =
               Memory.consolidate(session.id, ElixirClaw.MockProvider, threshold: 30)

      [summary_message] = persisted_messages(session.id)

      assert summary_message.role == "system"
      assert summary_message.content == summary
      assert summary_message.token_count == ContextBuilder.estimate_tokens(summary)
      refute summary_message.id in [first.id, second.id]
    end

    test "returns provider errors and preserves messages" do
      session = Factory.insert_session!()

      Factory.insert_message!(session_id: session.id, role: "user", content: "Hello there", token_count: 20)
      Factory.insert_message!(session_id: session.id, role: "assistant", content: "General Kenobi", token_count: 20)

      expect(ElixirClaw.MockProvider, :chat, fn _messages, _opts ->
        {:error, :upstream_timeout}
      end)

      assert {:error, :upstream_timeout} =
               Memory.consolidate(session.id, ElixirClaw.MockProvider, threshold: 30)

      assert ["General Kenobi", "Hello there"] ==
               session.id
               |> persisted_messages()
               |> Enum.map(& &1.content)
               |> Enum.sort()
    end
  end

  defp persisted_messages(session_id) do
    from(message in Message,
      where: message.session_id == ^session_id,
      order_by: [asc: message.inserted_at, asc: message.id]
    )
    |> Repo.all()
  end

  defp restore_memory_config(nil), do: Application.delete_env(:elixir_claw, Memory)
  defp restore_memory_config(config), do: Application.put_env(:elixir_claw, Memory, config)

  defp create_test_tables! do
    Repo.query!("PRAGMA foreign_keys = ON")

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY,
      channel TEXT NOT NULL,
      channel_user_id TEXT NOT NULL,
      provider TEXT NOT NULL,
      model TEXT,
      token_count_in INTEGER NOT NULL DEFAULT 0,
      token_count_out INTEGER NOT NULL DEFAULT 0,
      metadata TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS messages (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system', 'tool')),
      content TEXT NOT NULL,
      tool_calls TEXT,
      tool_call_id TEXT,
      token_count INTEGER NOT NULL DEFAULT 0,
      inserted_at TEXT NOT NULL,
      FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
    )
    """)

    Repo.query!("CREATE INDEX IF NOT EXISTS messages_session_id_index ON messages(session_id)")
  end
end
