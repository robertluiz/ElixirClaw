defmodule ElixirClaw.Resilience do
  @moduledoc false

  alias ElixirClaw.Resilience.{CircuitBreaker, RateLimiter}

  @retryable_errors [:timeout, :rate_limited, :server_error]
  @non_retryable_errors [:auth_error]

  @spec with_failover([term()], keyword(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def with_failover(providers, _opts, fun) when is_list(providers) and is_function(fun, 1) do
    do_with_failover(providers, fun)
  end

  @spec call_with_timeout((-> term()), timeout()) :: term() | {:error, :timeout}
  def call_with_timeout(fun, timeout_ms) when is_function(fun, 0) and is_integer(timeout_ms) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defdelegate start_link(opts), to: CircuitBreaker
  defdelegate call(server, provider_name, fun), to: CircuitBreaker
  defdelegate state(server, provider_name), to: CircuitBreaker

  defdelegate check_and_consume(server, entity_id, max_per_minute), to: RateLimiter

  defp do_with_failover([], _fun), do: {:error, :no_providers}

  defp do_with_failover([provider], fun), do: fun.(provider)

  defp do_with_failover([provider | rest], fun) do
    case fun.(provider) do
      {:ok, _result} = success ->
        success

      {:error, reason} = error when reason in @non_retryable_errors ->
        error

      {:error, reason} when reason in @retryable_errors ->
        :telemetry.execute(
          [:elixir_claw, :provider, :failover],
          %{},
          %{from_provider: provider_name(provider), reason: reason}
        )

        do_with_failover(rest, fun)

      {:error, _reason} = error ->
        error
    end
  end

  defp provider_name(provider) when is_binary(provider), do: provider

  defp provider_name(%{name: name}) when is_binary(name), do: name
  defp provider_name(%{"name" => name}) when is_binary(name), do: name

  defp provider_name(provider) when is_atom(provider) do
    if function_exported?(provider, :name, 0) do
      provider.name()
    else
      inspect(provider)
    end
  end

  defp provider_name(provider), do: inspect(provider)
end
