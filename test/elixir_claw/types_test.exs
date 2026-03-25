defmodule ElixirClaw.TypesTest do
  use ExUnit.Case, async: true

  alias ElixirClaw.Types.{Message, ProviderResponse, Session, TokenUsage, ToolCall}

  describe "Message" do
    test "struct enforces required fields" do
      msg = %Message{role: "user", content: "hello"}
      assert msg.role == "user"
      assert msg.content == "hello"
      assert msg.token_count == 0
      assert_raise ArgumentError, fn -> struct!(Message, []) end
    end

    test "estimated_tokens/1 returns rough estimate" do
      msg = %Message{role: "user", content: "hello world"}
      assert Message.estimated_tokens(msg) == div(String.length("hello world"), 4)
    end

    test "estimated_tokens/1 returns 0 for nil content" do
      msg = %Message{role: "tool", content: nil}
      assert Message.estimated_tokens(msg) == 0
    end
  end

  describe "Session" do
    test "struct with defaults" do
      session = %Session{id: "abc", channel: "cli", channel_user_id: "u1", provider: "openai"}
      assert session.messages == []
      assert session.token_count_in == 0
      assert session.token_count_out == 0
      assert session.metadata == %{}
    end

    test "inspect redacts sensitive metadata" do
      session = %Session{
        id: "abc",
        channel: "cli",
        channel_user_id: "u1",
        provider: "openai",
        metadata: %{"api_key" => "sk-secret-val", "safe_key" => "visible"}
      }

      inspected = inspect(session)
      assert inspected =~ "[REDACTED]"
      refute inspected =~ "sk-secret-val"
      assert inspected =~ "visible"
    end

    test "redact_metadata/1 redacts known sensitive keys" do
      meta = %{"api_key" => "s3cr3t", "token" => "abc", "safe" => "ok"}
      result = Session.redact_metadata(meta)
      assert result["api_key"] == "[REDACTED]"
      assert result["token"] == "[REDACTED]"
      assert result["safe"] == "ok"
    end

    test "redact_metadata/1 passes through non-map values" do
      assert Session.redact_metadata("plain") == "plain"
      assert Session.redact_metadata(42) == 42
    end
  end

  describe "ToolCall" do
    test "struct creation" do
      tc = %ToolCall{id: "tc1", name: "search", arguments: %{"query" => "elixir"}}
      assert tc.id == "tc1"
      assert tc.name == "search"
      assert tc.result == nil
    end

    test "enforces required fields" do
      assert_raise ArgumentError, fn -> struct!(ToolCall, []) end
    end
  end

  describe "ProviderResponse" do
    test "struct creation" do
      usage = %TokenUsage{input: 10, output: 20, total: 30}
      resp = %ProviderResponse{content: "Hello!", token_usage: usage}
      assert resp.content == "Hello!"
      assert resp.token_usage.total == 30
      assert resp.tool_calls == nil
    end

    test "enforces required content field" do
      assert_raise ArgumentError, fn -> struct!(ProviderResponse, []) end
    end
  end

  describe "TokenUsage" do
    test "add/2 sums correctly" do
      a = %TokenUsage{input: 10, output: 20, total: 30}
      b = %TokenUsage{input: 5, output: 15, total: 20}
      result = TokenUsage.add(a, b)
      assert result.input == 15
      assert result.output == 35
      assert result.total == 50
    end

    test "add/2 total equals input plus output" do
      a = %TokenUsage{input: 100, output: 200, total: 300}
      b = %TokenUsage{input: 50, output: 75, total: 125}
      result = TokenUsage.add(a, b)
      assert result.total == result.input + result.output
    end
  end
end
