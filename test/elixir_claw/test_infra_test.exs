defmodule ElixirClaw.TestInfraTest do
  use ExUnit.Case, async: true

  alias ElixirClaw.Test.{Fixtures, SecurityHelpers, TokenHelpers}
  alias ElixirClaw.Types.{Message, Session, TokenUsage}

  describe "Fixtures" do
    test "build_message/0 returns valid Message struct with defaults" do
      msg = Fixtures.build_message()
      assert %Message{} = msg
      assert msg.role == "user"
      assert msg.content == "test message"
      assert msg.token_count == 12
    end

    test "build_message/1 accepts overrides" do
      msg = Fixtures.build_message(role: "assistant", content: "hello")
      assert msg.role == "assistant"
      assert msg.content == "hello"
    end

    test "build_session/0 returns valid Session struct with defaults" do
      session = Fixtures.build_session()
      assert %Session{} = session
      assert session.channel == "cli"
      assert session.provider == "openai"
      assert session.messages == []
    end

    test "build_session/1 accepts overrides" do
      session = Fixtures.build_session(channel: "telegram", provider: "anthropic")
      assert session.channel == "telegram"
      assert session.provider == "anthropic"
    end

    test "build_token_usage/0 computes total from input + output" do
      usage = Fixtures.build_token_usage()
      assert usage.total == usage.input + usage.output
    end

    test "build_provider_response/0 returns valid ProviderResponse" do
      resp = Fixtures.build_provider_response()
      assert resp.content == "Test response"
      assert resp.finish_reason == "stop"
    end
  end

  describe "SecurityHelpers" do
    test "assert_no_secrets/1 passes for safe strings" do
      assert :ok = SecurityHelpers.assert_no_secrets("This is a safe log message")
      assert :ok = SecurityHelpers.assert_no_secrets("user@example.com logged in")
      assert :ok = SecurityHelpers.assert_no_secrets("")
    end

    test "assert_no_secrets/1 raises for OpenAI-style key" do
      assert_raise ExUnit.AssertionError, fn ->
        SecurityHelpers.assert_no_secrets("Using key sk-abcdefghijklmnopqrst")
      end
    end

    test "assert_no_secrets/1 raises for Bearer token" do
      assert_raise ExUnit.AssertionError, fn ->
        SecurityHelpers.assert_no_secrets("Authorization: Bearer eyJhbGciOiJSUzI1NiJ9")
      end
    end

    test "assert_not_in_output/2 passes when value absent" do
      assert :ok = SecurityHelpers.assert_not_in_output("safe message", "sk-secret")
    end

    test "assert_not_in_output/2 raises when value present" do
      assert_raise ExUnit.AssertionError, fn ->
        SecurityHelpers.assert_not_in_output("key=sk-mysecret", "sk-mysecret")
      end
    end
  end

  describe "TokenHelpers" do
    test "assert_token_count/2 passes when equal" do
      assert :ok = TokenHelpers.assert_token_count(42, 42)
    end

    test "assert_token_count/2 raises when mismatch" do
      assert_raise ExUnit.AssertionError, fn ->
        TokenHelpers.assert_token_count(10, 20)
      end
    end

    test "assert_within_budget/2 passes when under budget" do
      usage = %TokenUsage{input: 100, output: 200, total: 300}
      assert :ok = TokenHelpers.assert_within_budget(usage, 500)
    end

    test "assert_within_budget/2 raises when over budget" do
      usage = %TokenUsage{input: 500, output: 600, total: 1100}

      assert_raise ExUnit.AssertionError, fn ->
        TokenHelpers.assert_within_budget(usage, 1000)
      end
    end

    test "assert_tokens_tracked/1 passes with non-zero total" do
      usage = %TokenUsage{input: 10, output: 20, total: 30}
      assert :ok = TokenHelpers.assert_tokens_tracked(usage)
    end

    test "assert_tokens_tracked/1 raises when total is zero" do
      usage = %TokenUsage{input: 0, output: 0, total: 0}

      assert_raise ExUnit.AssertionError, fn ->
        TokenHelpers.assert_tokens_tracked(usage)
      end
    end
  end
end
