defmodule ElixirClaw.Test.Factory do
  @moduledoc """
  Ecto schema factory for creating persisted test records.
  Uses Ecto.Changeset + Repo.insert! so IDs and timestamps are set correctly.
  """

  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.{Message, Session}

  @doc """
  Insert a Session Ecto record into the test database.

  ## Options
    - `:channel` (default: "telegram")
    - `:channel_user_id` (default: auto-generated)
    - `:provider` (default: "openai")
    - `:model` (default: "gpt-4o-mini")
    - `:token_count_in` (default: 0)
    - `:token_count_out` (default: 0)
    - `:metadata` (default: nil)
  """
  @spec insert_session!(keyword()) :: Session.t()
  def insert_session!(opts \\ []) do
    attrs = %{
      channel: Keyword.get(opts, :channel, "telegram"),
      channel_user_id:
        Keyword.get(opts, :channel_user_id, "fixture-user-#{System.unique_integer([:positive])}"),
      provider: Keyword.get(opts, :provider, "openai"),
      model: Keyword.get(opts, :model, "gpt-4o-mini"),
      token_count_in: Keyword.get(opts, :token_count_in, 0),
      token_count_out: Keyword.get(opts, :token_count_out, 0),
      metadata: Keyword.get(opts, :metadata, nil)
    }

    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert!()
  end

  @doc """
  Insert a Message Ecto record into the test database.

  ## Options
    - `:session_id` (required) — parent session UUID
    - `:role` (default: "user")
    - `:content` (default: "fixture message")
    - `:token_count` (default: 12)
    - `:tool_calls` (default: nil)
    - `:tool_call_id` (default: nil)
  """
  @spec insert_message!(keyword()) :: Message.t()
  def insert_message!(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    attrs = %{
      session_id: session_id,
      role: Keyword.get(opts, :role, "user"),
      content: Keyword.get(opts, :content, "fixture message"),
      token_count: Keyword.get(opts, :token_count, 12),
      tool_calls: Keyword.get(opts, :tool_calls, nil),
      tool_call_id: Keyword.get(opts, :tool_call_id, nil)
    }

    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert!()
  end
end
