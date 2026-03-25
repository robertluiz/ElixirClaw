defmodule ElixirClaw.ResilienceTest do
  use ExUnit.Case, async: false

  alias ElixirClaw.Resilience
  alias ElixirClaw.Resilience.{CircuitBreaker, RateLimiter}

  describe "with_failover/3" do
    test "fails over from timeout to secondary provider and emits telemetry" do
      parent = self()

      telemetry_ref = make_ref()

      :telemetry.attach_many(
        telemetry_ref,
        [[:elixir_claw, :provider, :failover]],
        fn event, _measurements, metadata, _config ->
          send(parent, {event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(telemetry_ref) end)

      providers = ["primary", "secondary"]

      result =
        Resilience.with_failover(providers, [], fn
          "primary" -> {:error, :timeout}
          "secondary" -> {:ok, %{content: "from-secondary"}}
        end)

      assert {:ok, %{content: "from-secondary"}} = result

      assert_receive {[:elixir_claw, :provider, :failover],
                      %{from_provider: "primary", reason: :timeout}}
    end

    test "does not fail over on auth error" do
      counter = start_supervised!({Agent, fn -> 0 end})

      result =
        Resilience.with_failover(["primary", "secondary"], [], fn
          "primary" ->
            {:error, :auth_error}

          "secondary" ->
            Agent.update(counter, &(&1 + 1))
            {:ok, :should_not_happen}
        end)

      assert {:error, :auth_error} = result
      assert Agent.get(counter, & &1) == 0
    end
  end

  describe "call_with_timeout/2" do
    test "returns timeout when function exceeds the timeout" do
      assert {:error, :timeout} =
               Resilience.call_with_timeout(
                 fn ->
                   Process.sleep(100)
                   :ok
                 end,
                 10
               )
    end
  end

  describe "CircuitBreaker" do
    setup do
      server = start_supervised!({CircuitBreaker, open_timeout_ms: 50})
      %{server: server}
    end

    test "opens after three consecutive failures and rejects subsequent calls", %{server: server} do
      telemetry_ref = make_ref()
      parent = self()

      :telemetry.attach_many(
        telemetry_ref,
        [[:elixir_claw, :circuit_breaker, :open]],
        fn event, _measurements, metadata, _config ->
          send(parent, {event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(telemetry_ref) end)

      for _ <- 1..3 do
        assert {:error, :server_error} =
                 CircuitBreaker.call(server, "openai", fn -> {:error, :server_error} end)
      end

      assert :open = CircuitBreaker.state(server, "openai")

      assert_receive {[:elixir_claw, :circuit_breaker, :open], %{provider: "openai"}}

      assert {:error, :circuit_open} =
               CircuitBreaker.call(server, "openai", fn -> {:ok, :should_not_run} end)
    end

    test "transitions to half_open after timeout and closes on success", %{server: server} do
      for _ <- 1..3 do
        assert {:error, :server_error} =
                 CircuitBreaker.call(server, "anthropic", fn -> {:error, :server_error} end)
      end

      assert :open = CircuitBreaker.state(server, "anthropic")

      Process.sleep(60)

      assert :half_open = CircuitBreaker.state(server, "anthropic")

      assert {:ok, :recovered} =
               CircuitBreaker.call(server, "anthropic", fn -> {:ok, :recovered} end)

      assert :closed = CircuitBreaker.state(server, "anthropic")
    end

    test "rejects concurrent half_open probes while recovery call is in flight", %{server: server} do
      parent = self()

      for _ <- 1..3 do
        assert {:error, :server_error} =
                 CircuitBreaker.call(server, "anthropic", fn -> {:error, :server_error} end)
      end

      Process.sleep(60)
      assert :half_open = CircuitBreaker.state(server, "anthropic")

      probe_task =
        Task.async(fn ->
          CircuitBreaker.call(server, "anthropic", fn ->
            send(parent, :half_open_probe_started)

            receive do
              :release_half_open_probe -> {:ok, :recovered}
            end
          end)
        end)

      assert_receive :half_open_probe_started

      assert {:error, :circuit_open} =
               CircuitBreaker.call(server, "anthropic", fn -> {:ok, :second_probe} end)

      send(probe_task.pid, :release_half_open_probe)
      assert {:ok, :recovered} = Task.await(probe_task)
      assert :closed = CircuitBreaker.state(server, "anthropic")
    end
  end

  describe "RateLimiter" do
    test "allows up to the limit and rejects the next call" do
      now = Agent.start_link(fn -> 0 end) |> elem(1)

      server =
        start_supervised!({RateLimiter, time_fn: fn -> Agent.get(now, & &1) end})

      for _ <- 1..5 do
        assert :ok = RateLimiter.check_and_consume(server, "session-1", 5)
      end

      assert {:error, :rate_limited} = RateLimiter.check_and_consume(server, "session-1", 5)
    end
  end
end
