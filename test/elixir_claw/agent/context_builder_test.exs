defmodule ElixirClaw.Agent.ContextBuilderTest do
  use ExUnit.Case, async: true

  alias ElixirClaw.Agent.ContextBuilder
  alias ElixirClaw.Test.Fixtures

  describe "estimate_tokens/1" do
    test "returns minimum of one token" do
      assert ContextBuilder.estimate_tokens("") == 1
      assert ContextBuilder.estimate_tokens("hey") == 1
    end

    test "uses string length divided by four" do
      assert ContextBuilder.estimate_tokens("hello world!") == 3
    end
  end

  describe "sanitize_user_content/1" do
    test "strips known prompt injection markers but preserves normal content" do
      assert ContextBuilder.sanitize_user_content("say <|endoftext|> [INST] now <<SYS>> ok") ==
               "say endoftext  now  ok"
    end
  end

  describe "build_context/3" do
    test "returns system prompt and sanitized user message for empty conversation" do
      {messages, metadata} =
        ContextBuilder.build_context([], [],
          system_prompt: "You are helpful.",
          user_message: "please remove <|bad|>",
          max_tokens: 100
        )

      assert [
               %{role: "system", content: "You are helpful."},
               %{role: "user", content: "please remove bad"}
             ] = strip_token_counts(messages)

      assert metadata == %{token_count: 8, messages_included: 2, messages_dropped: 0}
      assert ContextBuilder.count_context_tokens(messages) == 8
    end

    test "assembles system prompt, capped skills, newest history, and user message in order" do
      session =
        Fixtures.build_session(
          messages: [
            Fixtures.build_message(role: "user", content: String.duplicate("a", 20)),
            Fixtures.build_message(role: "assistant", content: String.duplicate("b", 20)),
            Fixtures.build_message(role: "user", content: String.duplicate("c", 20))
          ]
        )

      {messages, metadata} =
        ContextBuilder.build_context(session, [String.duplicate("s", 8), String.duplicate("x", 20)],
          system_prompt: String.duplicate("p", 8),
          user_message: "final",
          max_tokens: 18,
          skill_token_budget: 2
        )

      assert [
               %{role: "system", content: system_prompt},
               %{role: "system", content: skills},
               %{role: "system", content: "[Earlier conversation summarized]"},
               %{role: "user", content: newest_history},
               %{role: "user", content: "final"}
             ] = strip_token_counts(messages)

      assert system_prompt == String.duplicate("p", 8)
      assert skills == String.duplicate("s", 8)
      assert newest_history == String.duplicate("c", 20)

      assert metadata == %{token_count: 18, messages_included: 5, messages_dropped: 2}
      assert ContextBuilder.count_context_tokens(messages) == 18
    end

    test "accepts a raw message list and keeps newest messages that fit the budget" do
      messages = [
        Fixtures.build_message(role: "user", content: String.duplicate("a", 20)),
        Fixtures.build_message(role: "assistant", content: String.duplicate("b", 20)),
        Fixtures.build_message(role: "user", content: String.duplicate("c", 20)),
        Fixtures.build_message(role: "assistant", content: String.duplicate("d", 20))
      ]

      {context, metadata} =
        ContextBuilder.build_context(messages, [],
          system_prompt: String.duplicate("p", 8),
          user_message: String.duplicate("u", 8),
          max_tokens: 22
        )

      assert [
               %{role: "system", content: _},
               %{role: "system", content: "[Earlier conversation summarized]"},
               %{role: "assistant", content: newest},
               %{role: "user", content: next_newest},
               %{role: "user", content: _}
             ] = strip_token_counts(context)

      assert newest == String.duplicate("d", 20)
      assert next_newest == String.duplicate("c", 20)
      assert metadata == %{token_count: 22, messages_included: 5, messages_dropped: 2}
    end
  end

  defp strip_token_counts(messages) do
    Enum.map(messages, fn message -> Map.take(message, [:role, :content]) end)
  end
end
