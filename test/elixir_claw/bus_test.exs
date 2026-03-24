defmodule ElixirClaw.BusTest do
  use ExUnit.Case, async: true

  alias ElixirClaw.Bus.MessageBus

  describe "subscribe/1 and publish/2" do
    test "publishes sanitized incoming messages to session topics" do
      topic = "session:test-session"

      payload = %{
        type: :incoming_message,
        content: "hello",
        api_key: "top-secret",
        nested: %{"token" => "remove-me", "safe" => "keep-me"}
      }

      assert :ok = MessageBus.subscribe(topic)
      assert :ok = MessageBus.publish(topic, payload)

      assert_receive %{
        type: :incoming_message,
        content: "hello",
        nested: %{"safe" => "keep-me"}
      }

      refute_received %{api_key: _}
      refute_received %{"token" => _}
    end

    test "publishes outgoing messages to channel topics" do
      topic = "channel:discord"
      payload = %{type: :outgoing_message, channel_name: "discord", content: "pong"}

      assert :ok = MessageBus.subscribe(topic)
      assert :ok = MessageBus.publish(topic, payload)

      assert_receive ^payload
    end

    test "broadcasts the same sanitized message to multiple subscribers" do
      topic = "session:fanout"
      payload = %{type: :tool_call_started, tool_name: "search", secret: "remove"}
      parent = self()

      subscriber =
        spawn_link(fn ->
          MessageBus.subscribe(topic)
          send(parent, :subscriber_ready)

          receive do
            message -> send(parent, {:subscriber_message, message})
          end
        end)

      assert_receive :subscriber_ready
      assert :ok = MessageBus.subscribe(topic)
      assert :ok = MessageBus.publish(topic, payload)

      assert_receive %{type: :tool_call_started, tool_name: "search"} = message
      assert_receive {:subscriber_message, ^message}

      refute Map.has_key?(message, :secret)
      Process.exit(subscriber, :normal)
    end

    test "unsubscribe/1 stops future deliveries" do
      topic = "channel:telegram"

      assert :ok = MessageBus.subscribe(topic)
      assert :ok = MessageBus.unsubscribe(topic)
      assert :ok = MessageBus.publish(topic, %{type: :error, reason: "boom"})

      refute_receive _, 50
    end

    test "preserves stream chunk token metadata when available" do
      topic = "session:stream"

      payload = %{
        type: :stream_chunk,
        chunk: "partial",
        metadata: %{
          token_count: 12,
          usage: %{input: 5, output: 7, total: 12}
        }
      }

      assert :ok = MessageBus.subscribe(topic)
      assert :ok = MessageBus.publish(topic, payload)

      assert_receive %{
        type: :stream_chunk,
        chunk: "partial",
        metadata: %{token_count: 12, usage: %{input: 5, output: 7, total: 12}}
      }
    end
  end

  describe "sanitize_payload/1" do
    test "removes sensitive keys recursively from nested maps" do
      payload = %{
        "token" => "remove",
        keep: "value",
        nested: %{
          api_key: "remove",
          keep_too: true,
          deep: %{"PASSWORD" => "remove", "ok" => 1}
        },
        list: [
          %{"secret" => "remove", "visible" => "yes"},
          %{safe: "still here"}
        ]
      }

      assert MessageBus.sanitize_payload(payload) == %{
               keep: "value",
               nested: %{
                 keep_too: true,
                 deep: %{"ok" => 1}
               },
               list: [
                 %{"visible" => "yes"},
                 %{safe: "still here"}
               ]
             }
    end
  end
end
