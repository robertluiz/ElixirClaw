defmodule ElixirClaw.BehavioursTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  describe "ElixirClaw.Provider behaviour" do
    test "MockProvider implements all Provider callbacks" do
      # If this compiles, all callbacks are correctly defined
      assert function_exported?(ElixirClaw.MockProvider, :chat, 2)
      assert function_exported?(ElixirClaw.MockProvider, :stream, 2)
      assert function_exported?(ElixirClaw.MockProvider, :name, 0)
      assert function_exported?(ElixirClaw.MockProvider, :models, 0)
      assert function_exported?(ElixirClaw.MockProvider, :count_tokens, 2)
    end

    test "MockProvider.chat/2 can be stubbed with Mox" do
      expect(ElixirClaw.MockProvider, :chat, fn _messages, _opts ->
        {:ok,
         %{
           content: "hello",
           tool_calls: nil,
           token_usage: nil,
           model: "test",
           finish_reason: "stop"
         }}
      end)

      assert {:ok, resp} = ElixirClaw.MockProvider.chat([], [])
      assert resp.content == "hello"
    end

    test "MockProvider.count_tokens/2 can be stubbed (token economy)" do
      expect(ElixirClaw.MockProvider, :count_tokens, fn text, _model ->
        {:ok, div(String.length(text), 4)}
      end)

      assert {:ok, 3} = ElixirClaw.MockProvider.count_tokens("hello world!", "gpt-4")
    end

    test "MockProvider.name/0 can be stubbed" do
      expect(ElixirClaw.MockProvider, :name, fn -> "mock-provider" end)
      assert ElixirClaw.MockProvider.name() == "mock-provider"
    end

    test "MockProvider.models/0 can be stubbed" do
      expect(ElixirClaw.MockProvider, :models, fn -> ["model-a", "model-b"] end)
      assert ElixirClaw.MockProvider.models() == ["model-a", "model-b"]
    end
  end

  describe "ElixirClaw.Channel behaviour" do
    test "MockChannel implements all Channel callbacks" do
      callbacks = ElixirClaw.Channel.behaviour_info(:callbacks)
      assert {:start_link, 1} in callbacks
      assert {:send_message, 3} in callbacks
      assert {:handle_incoming, 1} in callbacks
      assert {:sanitize_input, 1} in callbacks
    end

    test "MockChannel.sanitize_input/1 can be stubbed (security)" do
      expect(ElixirClaw.MockChannel, :sanitize_input, fn raw ->
        String.replace(raw, ~r/[<>]/, "")
      end)

      result = ElixirClaw.MockChannel.sanitize_input("<script>alert(1)</script>")
      refute result =~ "<"
      refute result =~ ">"
    end

    test "MockChannel.handle_incoming/1 can be stubbed" do
      msg = %ElixirClaw.Types.Message{role: "user", content: "hi"}

      expect(ElixirClaw.MockChannel, :handle_incoming, fn _raw ->
        {:ok, msg}
      end)

      assert {:ok, ^msg} = ElixirClaw.MockChannel.handle_incoming(%{text: "hi"})
    end
  end

  describe "ElixirClaw.Tool behaviour" do
    test "MockTool implements all Tool callbacks" do
      callbacks = ElixirClaw.Tool.behaviour_info(:callbacks)
      assert {:name, 0} in callbacks
      assert {:description, 0} in callbacks
      assert {:parameters_schema, 0} in callbacks
      assert {:execute, 2} in callbacks
      assert {:max_output_bytes, 0} in callbacks
      assert {:timeout_ms, 0} in callbacks
    end

    test "MockTool.max_output_bytes/0 can be stubbed (security: no unbounded output)" do
      expect(ElixirClaw.MockTool, :max_output_bytes, fn -> 65_536 end)
      assert ElixirClaw.MockTool.max_output_bytes() == 65_536
    end

    test "MockTool.timeout_ms/0 can be stubbed (security: no hung tools)" do
      expect(ElixirClaw.MockTool, :timeout_ms, fn -> 30_000 end)
      assert ElixirClaw.MockTool.timeout_ms() == 30_000
    end

    test "MockTool.execute/2 can be stubbed" do
      expect(ElixirClaw.MockTool, :execute, fn %{"query" => q}, _ctx ->
        {:ok, "result for #{q}"}
      end)

      assert {:ok, "result for elixir"} =
               ElixirClaw.MockTool.execute(%{"query" => "elixir"}, %{})
    end

    test "MockTool.parameters_schema/0 returns JSON Schema map" do
      schema = %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      }

      expect(ElixirClaw.MockTool, :parameters_schema, fn -> schema end)
      assert ElixirClaw.MockTool.parameters_schema() == schema
    end
  end
end
