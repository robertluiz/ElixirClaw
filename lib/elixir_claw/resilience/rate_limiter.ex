defmodule ElixirClaw.Resilience.RateLimiter do
  @moduledoc false

  use GenServer

  @minute_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, opts)
  end

  @spec check_and_consume(GenServer.server(), String.t(), pos_integer()) ::
          :ok | {:error, :rate_limited}
  def check_and_consume(server, entity_id, max_per_minute)
      when is_binary(entity_id) and is_integer(max_per_minute) and max_per_minute > 0 do
    GenServer.call(server, {:check_and_consume, entity_id, max_per_minute})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       buckets: %{},
       time_fn: Keyword.get(opts, :time_fn, fn -> System.monotonic_time(:millisecond) end)
     }}
  end

  @impl true
  def handle_call({:check_and_consume, entity_id, max_per_minute}, _from, state) do
    now_ms = state.time_fn.()
    bucket = Map.get(state.buckets, entity_id, new_bucket(max_per_minute, now_ms))
    refilled_bucket = refill(bucket, max_per_minute, now_ms)

    case refilled_bucket.tokens >= 1.0 do
      true ->
        next_bucket = %{
          refilled_bucket
          | tokens: refilled_bucket.tokens - 1.0,
            updated_at_ms: now_ms
        }

        {:reply, :ok, put_bucket(state, entity_id, next_bucket)}

      false ->
        {:reply, {:error, :rate_limited},
         put_bucket(state, entity_id, %{refilled_bucket | updated_at_ms: now_ms})}
    end
  end

  defp refill(bucket, max_per_minute, now_ms) do
    elapsed_ms = max(now_ms - bucket.updated_at_ms, 0)
    refill_tokens = elapsed_ms * max_per_minute / @minute_ms
    available_tokens = min(bucket.tokens + refill_tokens, max_per_minute * 1.0)

    %{bucket | tokens: available_tokens, updated_at_ms: now_ms, capacity: max_per_minute}
  end

  defp put_bucket(state, entity_id, bucket) do
    %{state | buckets: Map.put(state.buckets, entity_id, bucket)}
  end

  defp new_bucket(max_per_minute, now_ms) do
    %{tokens: max_per_minute * 1.0, updated_at_ms: now_ms, capacity: max_per_minute}
  end
end
