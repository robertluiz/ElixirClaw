defmodule ElixirClaw.Channels.Discord do
  @moduledoc false

  use GenServer

  require Logger

  alias ElixirClaw.Agent.Loop, as: AgentLoopModule
  alias ElixirClaw.Bus.MessageBus
  alias ElixirClaw.Session.Manager, as: SessionManagerModule
  alias ElixirClaw.Types.Message
  alias Nostrum.Api.Message, as: NostrumMessage

  @behaviour ElixirClaw.Channel
  @behaviour Nostrum.Consumer

  @max_message_length 2_000
  @help_message "Available commands: !help shows this message, !new starts a new session, !approve <tool...> approves privileged tools for the current session."
  @new_session_message "Started a new session."

  defmodule API do
    @callback create_message(channel_id :: term(), content :: String.t()) ::
                {:ok, term()} | {:error, term()}
  end

  defmodule NostrumAPI do
    @behaviour API

    @impl true
    def create_message(channel_id, content), do: NostrumMessage.create(channel_id, content)
  end

  defmodule SessionManager do
    @callback start_session(map()) :: {:ok, String.t()} | {:error, term()}
    @callback end_session(String.t()) :: :ok
    @callback approve_tools(String.t(), [String.t()]) :: :ok | {:error, term()}
  end

  defmodule DefaultSessionManager do
    @behaviour SessionManager

    @impl true
    def start_session(attrs), do: SessionManagerModule.start_session(attrs)

    @impl true
    def end_session(session_id), do: SessionManagerModule.end_session(session_id)

    @impl true
    def approve_tools(session_id, tool_names), do: SessionManagerModule.approve_tools(session_id, tool_names)
  end

  defmodule AgentLoop do
    @callback process_message(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  end

  defmodule DefaultAgentLoop do
    @behaviour AgentLoop

    @impl true
    def process_message(session_id, content),
      do: AgentLoopModule.process_message(session_id, content)
  end

  @type state :: %{
          api: module(),
          agent_loop: module(),
          bot_user_id: term(),
          model: String.t() | nil,
          provider: String.t() | nil,
          route_by_session: %{optional(String.t()) => %{channel_id: term(), user_id: term()}},
          session_by_user_channel: %{optional({term(), term()}) => String.t()},
          session_manager: module(),
          subscriptions: MapSet.t(String.t()),
          test_pid: pid() | nil
        }

  @impl true
  def start_link(config) when is_map(config) do
    case Map.get(config, :name, Map.get(config, "name")) do
      nil -> GenServer.start_link(__MODULE__, config)
      name -> GenServer.start_link(__MODULE__, config, name: name)
    end
  end

  @impl true
  def send_message(channel_pid, session_id, content)
      when is_pid(channel_pid) and is_binary(session_id) and is_binary(content) do
    GenServer.call(channel_pid, {:send_message, session_id, content})
  end

  @impl true
  def handle_incoming(%{content: content} = raw_message) when is_binary(content) do
    {:ok,
     %Message{
       role: "user",
       content: sanitize_input(content),
       timestamp: Map.get(raw_message, :timestamp)
     }}
  end

  def handle_incoming(%{"content" => content} = raw_message) when is_binary(content) do
    {:ok,
     %Message{
       role: "user",
       content: sanitize_input(content),
       timestamp: Map.get(raw_message, "timestamp")
     }}
  end

  def handle_incoming(_raw_message), do: {:error, :unsupported_message}

  @impl true
  def sanitize_input(raw) when is_binary(raw) do
    raw
    |> String.replace("<|", "")
    |> String.replace("|>", "")
    |> String.replace("[INST]", "")
    |> String.replace("<<SYS>>", "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @impl Nostrum.Consumer
  def handle_event({:MESSAGE_CREATE, message, ws_state}) do
    case consumer_pid(ws_state) do
      pid when is_pid(pid) ->
        GenServer.call(pid, {:discord_event, message})
        :ok

      _missing_pid ->
        :ok
    end
  end

  def handle_event(_event), do: :ok

  @impl true
  def init(config) do
    state = %{
      api: Map.get(config, :api, Application.get_env(:elixir_claw, :discord_api, NostrumAPI)),
      session_manager:
        Map.get(
          config,
          :session_manager,
          Application.get_env(:elixir_claw, :discord_session_manager, DefaultSessionManager)
        ),
      agent_loop:
        Map.get(
          config,
          :agent_loop,
          Application.get_env(:elixir_claw, :discord_agent_loop, DefaultAgentLoop)
        ),
      provider: Map.get(config, :provider),
      model: Map.get(config, :model),
      bot_user_id: Map.get(config, :bot_user_id),
      test_pid: Map.get(config, :test_pid),
      session_by_user_channel: %{},
      route_by_session: %{},
      subscriptions: MapSet.new()
    }

    allow_test_mocks(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, session_id, content}, _from, state) do
    case Map.get(state.route_by_session, session_id) do
      %{channel_id: channel_id} ->
        {:reply, deliver_content(state.api, channel_id, content), state}

      nil ->
        {:reply, {:error, :unknown_session}, state}
    end
  end

  def handle_call({:discord_event, raw_message}, _from, state) do
    {:reply, :ok, process_event(raw_message, state)}
  end

  @impl true
  def handle_info(%{type: :outgoing_message, session_id: session_id, content: content}, state) do
    _ = maybe_deliver(state, session_id, to_string(content))
    {:noreply, state}
  end

  def handle_info(%{type: :error, session_id: session_id, message: message}, state) do
    _ = maybe_deliver(state, session_id, to_string(message))
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp process_event(raw_message, state) do
    cond do
      bot_message?(raw_message) ->
        notify_test(state, {:discord_ignored, :bot_message})
        state

      self_message?(state.bot_user_id, raw_message) ->
        notify_test(state, {:discord_ignored, :self_message})
        state

      true ->
        handle_user_message(raw_message, state)
    end
  end

  defp handle_user_message(raw_message, state) do
    with {:ok, %Message{content: content}} <- handle_incoming(raw_message) do
      log_message_preview(content)

      cond do
        command?(content, "!help") ->
          _ = state.api.create_message(channel_id(raw_message), @help_message)
          state

        command?(content, "!new") ->
          start_new_session(raw_message, state)

        command?(content, "!approve") ->
          approve_tools_command(raw_message, content, state)

        dm_message?(raw_message) ->
          process_direct_message(raw_message, content, state)

        true ->
          notify_test(state, {:discord_ignored, :unsupported_message})
          state
      end
    else
      {:error, :unsupported_message} ->
        notify_test(state, {:discord_ignored, :unsupported_message})
        state
    end
  end

  defp process_direct_message(raw_message, content, state) do
    case ensure_session(raw_message, session_key(raw_message), state) do
      {:ok, session_id, updated_state} ->
        start_agent_loop_task(updated_state, session_id, content)
        updated_state

      {:error, reason, updated_state} ->
        Logger.warning("Discord session unavailable: #{inspect(reason)}")
        updated_state
    end
  end

  defp start_agent_loop_task(state, session_id, content) do
    Task.start(fn ->
      allow_test_mocks(state)

      case state.agent_loop.process_message(session_id, content) do
        {:ok, _response} ->
          :ok

        {:error, reason} ->
          Logger.warning("Discord agent loop failed: #{inspect(reason)}")
      end
    end)
  end

  defp start_new_session(raw_message, state) do
    key = session_key(raw_message)

    state =
      case Map.get(state.session_by_user_channel, key) do
        nil ->
          state

        existing_session_id ->
          :ok = state.session_manager.end_session(existing_session_id)
          drop_session(state, key, existing_session_id)
      end

    case create_session(raw_message, key, state) do
      {:ok, _session_id, updated_state} ->
        _ = state.api.create_message(channel_id(raw_message), @new_session_message)
        updated_state

      {:error, reason, updated_state} ->
        Logger.warning("Discord failed to create new session: #{inspect(reason)}")
        updated_state
    end
  end

  defp approve_tools_command(raw_message, content, state) do
    key = session_key(raw_message)
    tool_names = parse_approved_tool_names(content)

    case Map.get(state.session_by_user_channel, key) do
      nil ->
        _ = state.api.create_message(channel_id(raw_message), "No active session to approve tools for.")
        state

      session_id when tool_names == [] ->
        _ = state.api.create_message(channel_id(raw_message), "Usage: !approve <tool...>")
        put_session_mapping(state, key, session_id, raw_message)

      session_id ->
        case state.session_manager.approve_tools(session_id, tool_names) do
          :ok ->
            _ = state.api.create_message(channel_id(raw_message), approval_message(tool_names))
            put_session_mapping(state, key, session_id, raw_message)

          {:error, reason} ->
            Logger.warning("Discord failed to approve tools: #{inspect(reason)}")
            state
        end
    end
  end

  defp drop_session(state, key, session_id) do
    topic = topic(session_id)
    MessageBus.unsubscribe(topic)

    %{
      state
      | session_by_user_channel: Map.delete(state.session_by_user_channel, key),
        route_by_session: Map.delete(state.route_by_session, session_id),
        subscriptions: MapSet.delete(state.subscriptions, topic)
    }
  end

  defp ensure_session(raw_message, key, state) do
    case Map.get(state.session_by_user_channel, key) do
      nil -> create_session(raw_message, key, state)
      session_id -> {:ok, session_id, state}
    end
  end

  defp create_session(raw_message, key, state) do
    attrs = %{
      channel: "discord",
      channel_user_id: "#{user_id(raw_message)}:#{channel_id(raw_message)}",
      provider: state.provider,
      model: state.model,
      metadata: %{
        discord_user_id: user_id(raw_message),
        discord_channel_id: channel_id(raw_message)
      }
    }

    case state.session_manager.start_session(attrs) do
      {:ok, session_id} ->
        updated_state =
          state
          |> subscribe_to_session(session_id)
          |> put_session_mapping(key, session_id, raw_message)

        {:ok, session_id, updated_state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp subscribe_to_session(state, session_id) do
    topic = topic(session_id)

    if MapSet.member?(state.subscriptions, topic) do
      state
    else
      :ok = MessageBus.subscribe(topic)
      %{state | subscriptions: MapSet.put(state.subscriptions, topic)}
    end
  end

  defp put_session_mapping(state, key, session_id, raw_message) do
    state
    |> put_in([:session_by_user_channel, key], session_id)
    |> put_in([:route_by_session, session_id], %{
      channel_id: channel_id(raw_message),
      user_id: user_id(raw_message)
    })
  end

  defp maybe_deliver(state, session_id, content) do
    case Map.get(state.route_by_session, session_id) do
      %{channel_id: channel_id} -> deliver_content(state.api, channel_id, content)
      nil -> {:error, :unknown_session}
    end
  end

  defp deliver_content(api, channel_id, content) do
    content
    |> split_content()
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case api.create_message(channel_id, chunk) do
        {:ok, _message} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp split_content(content) when byte_size(content) <= @max_message_length, do: [content]

  defp split_content(content) do
    {chunk, rest} = String.split_at(content, @max_message_length)
    [chunk | split_content(rest)]
  end

  defp log_message_preview(content) do
    preview = String.slice(content, 0, 50)

    Logger.debug(fn ->
      suffix = if String.length(content) > 50, do: "…", else: ""
      "Discord message received: #{preview}#{suffix}"
    end)
  end

  defp allow_test_mocks(%{test_pid: test_pid} = state) when is_pid(test_pid) do
    maybe_allow_mock(state.api, test_pid)
    maybe_allow_mock(state.session_manager, test_pid)
    maybe_allow_mock(state.agent_loop, test_pid)
  end

  defp allow_test_mocks(_state), do: :ok

  defp maybe_allow_mock(module, owner_pid) do
    if Code.ensure_loaded?(Mox) and function_exported?(module, :__mock_for__, 0) do
      apply(Mox, :allow, [module, owner_pid, self()])
    end
  end

  defp notify_test(%{test_pid: pid}, message) when is_pid(pid), do: send(pid, message)
  defp notify_test(_state, _message), do: :ok

  defp parse_approved_tool_names(content) do
    content
    |> String.replace_prefix("!approve", "")
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp approval_message(tool_names) do
    "Approved tools: #{Enum.join(tool_names, ", ")}"
  end

  defp command?(content, command), do: String.starts_with?(String.trim_leading(content), command)

  defp dm_message?(raw_message),
    do: is_nil(Map.get(raw_message, :guild_id, Map.get(raw_message, "guild_id")))

  defp bot_message?(raw_message),
    do: Map.get(author(raw_message), :bot, Map.get(author(raw_message), "bot")) == true

  defp self_message?(nil, _raw_message), do: false
  defp self_message?(bot_user_id, raw_message), do: user_id(raw_message) == bot_user_id

  defp author(raw_message), do: Map.get(raw_message, :author, Map.get(raw_message, "author", %{}))

  defp user_id(raw_message),
    do: Map.get(author(raw_message), :id, Map.get(author(raw_message), "id"))

  defp channel_id(raw_message),
    do: Map.get(raw_message, :channel_id, Map.get(raw_message, "channel_id"))

  defp session_key(raw_message), do: {user_id(raw_message), channel_id(raw_message)}

  defp consumer_pid(%{pid: pid}) when is_pid(pid), do: pid
  defp consumer_pid(%{"pid" => pid}) when is_pid(pid), do: pid
  defp consumer_pid(_ws_state), do: nil

  defp topic(session_id), do: "session:#{session_id}"
end
