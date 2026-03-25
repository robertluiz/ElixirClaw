defmodule ElixirClaw.Resilience.CircuitBreaker do
  @moduledoc false

  use GenServer

  @failure_threshold 3
  @default_open_timeout_ms 60_000

  @type circuit_state :: :closed | :open | :half_open

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, opts)
  end

  @spec call(GenServer.server(), String.t(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def call(server, provider_name, fun)
      when is_binary(provider_name) and is_function(fun, 0) do
    case GenServer.call(server, {:allow_call, provider_name}) do
      {:error, :circuit_open} = error ->
        error

      :ok ->
        result = fun.()
        GenServer.call(server, {:record_result, provider_name, result})
        result
    end
  end

  @spec state(GenServer.server(), String.t()) :: circuit_state()
  def state(server, provider_name) when is_binary(provider_name) do
    GenServer.call(server, {:state, provider_name})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       circuits: %{},
       open_timeout_ms: Keyword.get(opts, :open_timeout_ms, @default_open_timeout_ms)
     }}
  end

  @impl true
  def handle_call({:allow_call, provider_name}, _from, state) do
    {circuit_state, next_state} = current_state(state, provider_name)

    case circuit_state do
      :open ->
        {:reply, {:error, :circuit_open}, next_state}

      :closed ->
        {:reply, :ok, next_state}

      :half_open ->
        if in_flight?(next_state, provider_name) do
          {:reply, {:error, :circuit_open}, next_state}
        else
          {:reply, :ok, put_in_flight(next_state, provider_name)}
        end
    end
  end

  def handle_call({:record_result, provider_name, result}, _from, state) do
    {_current, normalized_state} = current_state(state, provider_name)
    updated_state = update_circuit(normalized_state, provider_name, result)
    {:reply, :ok, updated_state}
  end

  def handle_call({:state, provider_name}, _from, state) do
    {circuit_state, next_state} = current_state(state, provider_name)
    {:reply, circuit_state, next_state}
  end

  defp current_state(state, provider_name) do
    circuit = Map.get(state.circuits, provider_name, new_circuit())

    case {circuit.state, open_timed_out?(circuit, state.open_timeout_ms)} do
      {:open, true} ->
        updated_circuit = %{circuit | state: :half_open, in_flight?: false}
        {:half_open, put_circuit(state, provider_name, updated_circuit)}

      _other ->
        {circuit.state, put_circuit(state, provider_name, circuit)}
    end
  end

  defp update_circuit(state, provider_name, {:ok, _result}) do
    circuit = Map.get(state.circuits, provider_name, new_circuit())

    next_circuit =
      case circuit.state do
        :half_open ->
          %{state: :closed, consecutive_failures: 0, opened_at_ms: nil, in_flight?: false}

        _other ->
          %{
            circuit
            | state: :closed,
              consecutive_failures: 0,
              opened_at_ms: nil,
              in_flight?: false
          }
      end

    put_circuit(state, provider_name, next_circuit)
  end

  defp update_circuit(state, provider_name, {:error, _reason}) do
    circuit = Map.get(state.circuits, provider_name, new_circuit())

    case circuit.state do
      :half_open ->
        open_circuit(state, provider_name, %{circuit | consecutive_failures: @failure_threshold})

      _other ->
        failures = circuit.consecutive_failures + 1

        if failures >= @failure_threshold do
          open_circuit(state, provider_name, %{circuit | consecutive_failures: failures})
        else
          put_circuit(state, provider_name, %{
            circuit
            | consecutive_failures: failures,
              in_flight?: false
          })
        end
    end
  end

  defp open_circuit(state, provider_name, circuit) do
    :telemetry.execute(
      [:elixir_claw, :circuit_breaker, :open],
      %{},
      %{provider: provider_name}
    )

    put_circuit(state, provider_name, %{
      circuit
      | state: :open,
        opened_at_ms: now_ms(),
        in_flight?: false
    })
  end

  defp put_in_flight(state, provider_name) do
    update_in(state, [:circuits, provider_name], fn
      nil -> %{new_circuit() | state: :half_open, in_flight?: true}
      circuit -> %{circuit | in_flight?: true}
    end)
  end

  defp in_flight?(state, provider_name) do
    state.circuits
    |> Map.get(provider_name, new_circuit())
    |> Map.get(:in_flight?, false)
  end

  defp put_circuit(state, provider_name, circuit) do
    %{state | circuits: Map.put(state.circuits, provider_name, circuit)}
  end

  defp open_timed_out?(%{opened_at_ms: nil}, _open_timeout_ms), do: false

  defp open_timed_out?(%{opened_at_ms: opened_at_ms}, open_timeout_ms) do
    now_ms() - opened_at_ms >= open_timeout_ms
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp new_circuit do
    %{state: :closed, consecutive_failures: 0, opened_at_ms: nil, in_flight?: false}
  end
end
