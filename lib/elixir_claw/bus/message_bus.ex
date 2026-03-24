defmodule ElixirClaw.Bus.MessageBus do
  @moduledoc """
  Phoenix.PubSub-backed message bus for session and channel communication.
  """

  @pubsub ElixirClaw.PubSub
  @sensitive_key_pattern ~r/(api_key|token|secret|password)/i
  @message_types [
    :incoming_message,
    :outgoing_message,
    :tool_call_started,
    :tool_call_completed,
    :stream_chunk,
    :error
  ]

  @type topic :: String.t()
  @type message_type ::
          :incoming_message
          | :outgoing_message
          | :tool_call_started
          | :tool_call_completed
          | :stream_chunk
          | :error

  @spec subscribe(topic()) :: :ok | {:error, term()}
  def subscribe(topic) when is_binary(topic) do
    Phoenix.PubSub.subscribe(@pubsub, topic)
  end

  @spec unsubscribe(topic()) :: :ok
  def unsubscribe(topic) when is_binary(topic) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic)
  end

  @spec publish(topic(), map()) :: :ok | {:error, term()}
  def publish(topic, %{type: type} = payload) when is_binary(topic) and type in @message_types do
    Phoenix.PubSub.broadcast(@pubsub, topic, sanitize_payload(payload))
  end

  def publish(topic, %{"type" => type} = payload)
      when is_binary(topic) and type in @message_types do
    Phoenix.PubSub.broadcast(@pubsub, topic, sanitize_payload(payload))
  end

  def publish(_topic, _payload), do: {:error, :invalid_message}

  @spec sanitize_payload(term()) :: term()
  def sanitize_payload(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> sanitize_payload()
    |> then(&struct(struct.__struct__, &1))
  end

  def sanitize_payload(map) when is_map(map) do
    map
    |> Enum.reject(fn {key, _value} -> sensitive_key?(key) end)
    |> Enum.into(%{}, fn {key, value} -> {key, sanitize_payload(value)} end)
  end

  def sanitize_payload(list) when is_list(list), do: Enum.map(list, &sanitize_payload/1)
  def sanitize_payload(payload), do: payload

  defp sensitive_key?(key) when is_atom(key), do: sensitive_key?(Atom.to_string(key))
  defp sensitive_key?("token_count"), do: false
  defp sensitive_key?(key) when is_binary(key), do: String.match?(key, @sensitive_key_pattern)
  defp sensitive_key?(_key), do: false
end
