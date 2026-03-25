defmodule ElixirClaw.Providers.Codex.TokenManager do
  @moduledoc """
  OAuth token storage with disk persistence and lazy refresh.
  """

  use GenServer

  alias ElixirClaw.Providers.Codex.OAuth
  alias ElixirClaw.Providers.OAuthTokenStore

  @refresh_threshold_seconds 300
  @initial_state %{access_token: nil, refresh_token: nil, expires_at: nil}

  @type state :: %{
          access_token: String.t() | nil,
          refresh_token: String.t() | nil,
          expires_at: DateTime.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec store_token(map()) :: :ok
  def store_token(token_response) when is_map(token_response) do
    GenServer.call(__MODULE__, {:store_token, token_response})
  end

  @spec persist_token_response(map()) :: :ok | {:error, term()}
  def persist_token_response(token_response) when is_map(token_response) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        store_token(token_response)

      nil ->
        @initial_state
        |> Map.merge(OAuthTokenStore.load("codex"))
        |> normalize_state()
        |> merge_token_response(token_response)
        |> persist_state()
    end
  end

  @spec get_token() :: {:ok, String.t()} | {:error, :no_token}
  def get_token do
    GenServer.call(__MODULE__, :get_token)
  end

  @spec token_valid?() :: boolean()
  def token_valid? do
    GenServer.call(__MODULE__, :token_valid?)
  end

  @spec clear_token() :: :ok
  def clear_token do
    GenServer.call(__MODULE__, :clear_token)
  end

  @impl true
  def init(:ok) do
    {:ok, load_state()}
  end

  @impl true
  def handle_call({:store_token, token_response}, _from, state) do
    updated_state = merge_token_response(state, token_response)
    {:reply, persist_state(updated_state), updated_state}
  end

  @impl true
  def handle_call(:get_token, _from, state) do
    case ensure_current_token(state) do
      {:ok, updated_state} ->
        {:reply, {:ok, updated_state.access_token}, updated_state}

      {:error, :no_token} ->
        {:reply, {:error, :no_token}, clear_state()}
    end
  end

  @impl true
  def handle_call(:token_valid?, _from, state) do
    {:reply, token_valid_state?(state), state}
  end

  @impl true
  def handle_call(:clear_token, _from, _state) do
    cleared_state = clear_state()
    {:reply, persist_state(cleared_state), cleared_state}
  end

  defp ensure_current_token(%{access_token: nil} = _state), do: {:error, :no_token}
  defp ensure_current_token(%{expires_at: nil} = _state), do: {:error, :no_token}

  defp ensure_current_token(state) do
    cond do
      expired?(state) ->
        refresh_state(state)

      refresh_required?(state) ->
        case refresh_state(state) do
          {:ok, refreshed_state} -> {:ok, refreshed_state}
          {:error, :no_token} -> {:ok, state}
        end

      true ->
        {:ok, state}
    end
  end

  defp refresh_state(%{refresh_token: nil}), do: {:error, :no_token}

  defp refresh_state(state) do
    case OAuth.refresh_token(state.refresh_token, []) do
      {:ok, token_response} ->
        refreshed_state = merge_token_response(state, token_response)
        :ok = persist_state(refreshed_state)
        {:ok, refreshed_state}

      {:error, _reason} ->
        {:error, :no_token}
    end
  end

  defp merge_token_response(state, token_response) do
    expires_in = fetch_token_value(token_response, :expires_in)

    %{
      access_token: fetch_token_value(token_response, :access_token),
      refresh_token: fetch_token_value(token_response, :refresh_token) || state.refresh_token,
      expires_at: DateTime.add(DateTime.utc_now(), expires_in, :second)
    }
  end

  defp fetch_token_value(token_response, key) when is_atom(key) do
    Map.get(token_response, key) || Map.get(token_response, Atom.to_string(key))
  end

  defp token_valid_state?(%{access_token: access_token, expires_at: %DateTime{} = expires_at})
       when is_binary(access_token) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  defp token_valid_state?(_state), do: false

  defp expired?(state), do: not token_valid_state?(state)

  defp refresh_required?(%{expires_at: %DateTime{} = expires_at}) do
    DateTime.diff(expires_at, DateTime.utc_now(), :second) < @refresh_threshold_seconds
  end

  defp refresh_required?(_state), do: false

  defp clear_state, do: @initial_state

  defp load_state do
    @initial_state
    |> Map.merge(OAuthTokenStore.load("codex"))
    |> normalize_state()
  end

  defp persist_state(state) do
    OAuthTokenStore.persist("codex", state)
  end

  defp normalize_state(state) do
    %{
      access_token: Map.get(state, :access_token),
      refresh_token: Map.get(state, :refresh_token),
      expires_at: Map.get(state, :expires_at)
    }
  end
end
