defmodule ElixirClaw.Channels.Telegram do
  @moduledoc """
  Telegram channel integration backed by Telegex.
  """

  use GenServer

  require Logger

  alias ElixirClaw.Agent.Loop, as: AgentLoopModule
  alias ElixirClaw.Bus.MessageBus
  alias ElixirClaw.Channel
  alias ElixirClaw.Session.Manager
  alias ElixirClaw.Types.Message

  @behaviour Channel

  @telegram_limit 4096
  @token_pattern ~r/^\d+:[A-Za-z0-9_-]+$/
  @markers ["<|", "|>", "[INST]", "[/INST]", "<<SYS>>", "<</SYS>>"]
  @start_message "Welcome to ElixirClaw Telegram. Send a message to begin, or use /help."
  @help_message "Available commands: /start, /help, /new, /approve <tool...>"
  @new_session_message "Started a new session for this chat."

  defmodule API do
    @moduledoc false

    @callback send_message(chat_id :: integer(), text :: String.t()) ::
                {:ok, term()} | {:error, term()}

    @callback get_updates(keyword()) :: {:ok, list(term())} | {:error, term()}
    @callback delete_webhook(keyword()) :: {:ok, term()} | {:error, term()}
    @callback get_me() :: {:ok, term()} | {:error, term()}
  end

  defmodule TelegexAPI do
    @moduledoc false
    @behaviour API

    @impl true
    def send_message(chat_id, text), do: Telegex.send_message(chat_id, text)

    @impl true
    def get_updates(opts), do: Telegex.get_updates(opts)

    @impl true
    def delete_webhook(opts), do: Telegex.delete_webhook(opts)

    @impl true
    def get_me, do: Telegex.get_me()
  end

  defmodule AgentLoop do
    @moduledoc false

    @callback process_message(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  end

  defmodule DefaultAgentLoop do
    @moduledoc false
    @behaviour AgentLoop

    @impl true
    def process_message(session_id, content),
      do: AgentLoopModule.process_message(session_id, content)
  end

  @type state :: %{
          telegex_api: module(),
          agent_loop: module(),
          chat_sessions: %{optional(integer()) => String.t()},
          session_chats: %{optional(String.t()) => integer()},
          provider: String.t(),
          model: String.t() | nil,
          poll_inflight?: boolean(),
          poll_interval: non_neg_integer(),
          poll_limit: pos_integer(),
          poll_offset: non_neg_integer(),
          poll_timeout: non_neg_integer(),
          poll_allowed_updates: [String.t()],
          start_polling?: boolean(),
          test_pid: pid() | nil
        }

  @impl Channel
  @spec start_link(map() | keyword()) :: GenServer.on_start() | {:error, :invalid_token}
  def start_link(config \\ %{})

  def start_link(config) do
    merged_config = merged_config(config)

    with {:ok, bot_token} <- fetch_valid_bot_token(merged_config) do
      Application.put_env(:telegex, :token, bot_token)
      GenServer.start_link(__MODULE__, merged_config)
    end
  end

  @spec process_update(pid(), map()) :: {:ok, String.t() | :command_handled} | {:error, term()}
  def process_update(channel_pid, update) when is_pid(channel_pid) and is_map(update) do
    GenServer.call(channel_pid, {:process_update, update})
  end

  @impl Channel
  @spec send_message(pid(), String.t(), String.t()) :: :ok | {:error, term()}
  def send_message(channel_pid, session_id, content)
      when is_pid(channel_pid) and is_binary(session_id) and is_binary(content) do
    GenServer.call(channel_pid, {:send_message, session_id, content})
  end

  @impl Channel
  @spec handle_incoming(map()) :: {:ok, Message.t()} | {:error, term()}
  def handle_incoming(raw_message) when is_map(raw_message) do
    with {:ok, "private"} <- fetch_chat_type(raw_message),
         {:ok, text} <- fetch_text(raw_message) do
      {:ok,
       %Message{
         role: "user",
         content: sanitize_input(text),
         timestamp: parse_timestamp(fetch_date(raw_message))
       }}
    end
  end

  @impl Channel
  @spec sanitize_input(String.t()) :: String.t()
  def sanitize_input(raw) when is_binary(raw) do
    Enum.reduce(@markers, raw, fn marker, acc -> String.replace(acc, marker, " ") end)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @impl true
  def init(config) do
    state = %{
      telegex_api: Keyword.get(config, :telegex_api, TelegexAPI),
      agent_loop: Keyword.get(config, :agent_loop, DefaultAgentLoop),
      chat_sessions: %{},
      session_chats: %{},
      provider: Keyword.get(config, :provider, runtime_default_provider()),
      model: Keyword.get(config, :model, runtime_default_model()),
      poll_inflight?: false,
      poll_interval: Keyword.get(config, :poll_interval, 35),
      poll_limit: Keyword.get(config, :poll_limit, 100),
      poll_offset: Keyword.get(config, :poll_offset, 0),
      poll_timeout: Keyword.get(config, :poll_timeout, 20),
      poll_allowed_updates: Keyword.get(config, :poll_allowed_updates, ["message"]),
      start_polling?: Keyword.get(config, :start_polling, true),
      test_pid: Keyword.get(config, :test_pid)
    }

    state = maybe_boot_polling(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:process_update, update}, _from, state) do
    {reply, next_state} = process_update_call(update, state)
    {:reply, reply, next_state}
  end

  def handle_call({:send_message, session_id, content}, _from, state) do
    {:reply, deliver_to_session(state, session_id, content), state}
  end

  @impl true
  def handle_info(%{type: :outgoing_message, session_id: session_id, content: content}, state) do
    case deliver_to_session(state, session_id, content) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Telegram send failed for session #{session_id}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(%{type: :error, session_id: session_id, message: content}, state) do
    case deliver_to_session(state, session_id, content) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Telegram error delivery failed for session #{session_id}: #{inspect(reason)}"
        )
    end

    {:noreply, state}
  end

  def handle_info(:poll_updates, %{start_polling?: true, poll_inflight?: false} = state) do
    {:noreply, start_poll_task(state)}
  end

  def handle_info(:poll_updates, state), do: {:noreply, state}

  def handle_info({:telegram_polled, previous_offset, {:ok, updates}}, state) do
    {next_offset, next_state} = process_polled_updates(List.wrap(updates), previous_offset, state)

    schedule_poll(next_state.poll_interval)

    {:noreply, %{next_state | poll_inflight?: false, poll_offset: next_offset}}
  end

  def handle_info({:telegram_polled, _previous_offset, {:error, reason}}, state) do
    log_polling_result(reason)
    schedule_poll(state.poll_interval)
    {:noreply, %{state | poll_inflight?: false}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp process_update_call(update, state) do
    with {:ok, chat_id} <- fetch_chat_id(update),
         {:ok, %Message{} = message} <- handle_incoming(update) do
      log_incoming(chat_id, message.content)

      case command_for(message.content) do
        :start ->
          {send_direct_message(state, chat_id, @start_message), state}

        :help ->
          {send_direct_message(state, chat_id, @help_message), state}

        :new ->
          case restart_session(chat_id, state) do
            {{:ok, session_id}, next_state} ->
              {send_direct_message(next_state, chat_id, @new_session_message, session_id),
               next_state}

            {error, next_state} ->
              {error, next_state}
          end

        {:approve, tool_names} ->
          case ensure_session(chat_id, state) do
            {{:ok, session_id}, next_state} ->
              case {tool_names, Manager.approve_tools(session_id, tool_names)} do
                {[], _result} ->
                  {send_direct_message(
                     next_state,
                     chat_id,
                     "Usage: /approve <tool...>",
                     session_id
                   ), next_state}

                {_tools, :ok} ->
                  {send_direct_message(
                     next_state,
                     chat_id,
                     approval_message(tool_names),
                     session_id
                   ), next_state}

                {_tools, {:error, reason}} ->
                  {{:error, reason}, next_state}
              end

            {error, next_state} ->
              {error, next_state}
          end

        nil ->
          case ensure_session(chat_id, state) do
            {{:ok, session_id}, next_state} ->
              payload = %{
                type: :incoming_message,
                session_id: session_id,
                content: message.content,
                channel: "telegram",
                  chat_id: chat_id
                }

              case MessageBus.publish(topic(session_id), payload)
                   |> normalize_publish_result(session_id) do
                {:ok, ^session_id} = result ->
                  start_agent_loop_task(next_state, session_id, message.content)
                  {result, next_state}

                error ->
                  {error, next_state}
              end

            {error, next_state} ->
              {error, next_state}
          end
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp normalize_publish_result(:ok, session_id), do: {:ok, session_id}
  defp normalize_publish_result({:error, reason}, _session_id), do: {:error, reason}

  defp maybe_boot_polling(%{start_polling?: true} = state) do
    allow_test_mocks(state)
    maybe_delete_webhook(state.telegex_api)
    log_bot_ready(state.telegex_api)
    schedule_poll(0)
    state
  end

  defp maybe_boot_polling(state), do: state

  defp restart_session(chat_id, state) do
    state = maybe_end_existing_session(chat_id, state)
    ensure_session(chat_id, state)
  end

  defp maybe_end_existing_session(chat_id, state) do
    case Map.get(state.chat_sessions, chat_id) do
      nil ->
        state

      session_id ->
        :ok = MessageBus.unsubscribe(topic(session_id))
        :ok = Manager.end_session(session_id)
        drop_session(state, chat_id, session_id)
    end
  end

  defp drop_session(state, chat_id, session_id) do
    %{
      state
      | chat_sessions: Map.delete(state.chat_sessions, chat_id),
        session_chats: Map.delete(state.session_chats, session_id)
    }
  end

  defp ensure_session(chat_id, state) do
    case Map.get(state.chat_sessions, chat_id) do
      nil -> create_session(chat_id, state)
      session_id -> {{:ok, session_id}, state}
    end
  end

  defp create_session(chat_id, state) do
    attrs = %{
      channel: "telegram",
      channel_user_id: Integer.to_string(chat_id),
      provider: state.provider,
      model: state.model,
      metadata: %{"chat_id" => chat_id}
    }

    with {:ok, session_id} <- Manager.start_session(attrs),
         :ok <- MessageBus.subscribe(topic(session_id)) do
      next_state = %{
        state
        | chat_sessions: Map.put(state.chat_sessions, chat_id, session_id),
          session_chats: Map.put(state.session_chats, session_id, chat_id)
      }

      {{:ok, session_id}, next_state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp start_agent_loop_task(state, session_id, content) do
    Task.start(fn ->
      allow_test_mocks(state)

      case state.agent_loop.process_message(session_id, content) do
        {:ok, _response} ->
          :ok

        {:error, reason} ->
          Logger.warning("Telegram agent loop failed: #{inspect(reason)}")
      end
    end)
  end

  defp start_poll_task(state) do
    server = self()
    updates_opts = [
      offset: state.poll_offset,
      limit: state.poll_limit,
      timeout: state.poll_timeout,
      allowed_updates: state.poll_allowed_updates
    ]

    Task.start(fn ->
      allow_test_mocks(state)
      send(server, {:telegram_polled, state.poll_offset, state.telegex_api.get_updates(updates_opts)})
    end)

    %{state | poll_inflight?: true}
  end

  defp process_polled_updates(updates, current_offset, state) do
    Enum.reduce(updates, {current_offset, state}, fn update, {offset, acc_state} ->
      next_offset = max(offset, update_id(update) + 1)

      case process_update_call(update, acc_state) do
        {{:error, reason}, next_state} ->
          Logger.warning("Telegram update handling failed: #{inspect(reason)}")
          {next_offset, next_state}

        {_reply, next_state} ->
          {next_offset, next_state}
      end
    end)
  end

  defp maybe_delete_webhook(api) do
    case api.delete_webhook(drop_pending_updates: false) do
      {:ok, _result} -> :ok
      {:error, reason} -> Logger.warning("Telegram delete_webhook failed: #{inspect(reason)}")
    end
  end

  defp log_bot_ready(api) do
    case api.get_me() do
      {:ok, %{username: username}} when is_binary(username) ->
        Logger.info("Telegram bot @#{username} connected")

      {:ok, %{"username" => username}} when is_binary(username) ->
        Logger.info("Telegram bot @#{username} connected")

      {:ok, _bot} ->
        Logger.info("Telegram bot connected")

      {:error, reason} ->
        Logger.warning("Telegram get_me failed: #{inspect(reason)}")
    end
  end

  defp allow_test_mocks(%{test_pid: test_pid} = state) when is_pid(test_pid) do
    maybe_allow_mock(state.telegex_api, test_pid)
    maybe_allow_mock(state.agent_loop, test_pid)
  end

  defp allow_test_mocks(_state), do: :ok

  defp maybe_allow_mock(module, owner_pid) do
    if Code.ensure_loaded?(Mox) and function_exported?(module, :__mock_for__, 0) do
      apply(Mox, :allow, [module, owner_pid, self()])
    end
  end

  defp schedule_poll(delay), do: Process.send_after(self(), :poll_updates, delay)

  defp update_id(update) when is_map(update) do
    Map.get(update, :update_id, Map.get(update, "update_id", 0)) || 0
  end

  defp deliver_to_session(state, session_id, content) do
    case Map.get(state.session_chats, session_id) do
      nil -> {:error, :unknown_session}
      chat_id -> deliver_chunks(state.telegex_api, chat_id, split_message(content))
    end
  end

  defp send_direct_message(state, chat_id, content, session_id \\ :command_handled) do
    case deliver_chunks(state.telegex_api, chat_id, split_message(content)) do
      :ok -> {:ok, session_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver_chunks(_api, _chat_id, []), do: :ok

  defp deliver_chunks(api, chat_id, chunks) do
    Enum.reduce_while(chunks, :ok, fn chunk, :ok ->
      case api.send_message(chat_id, chunk) do
        {:ok, _response} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp split_message(content) when is_binary(content) and byte_size(content) <= @telegram_limit,
    do: [content]

  defp split_message(content) when is_binary(content) do
    do_split_message(content, [])
  end

  defp do_split_message(<<>>, acc), do: Enum.reverse(acc)

  defp do_split_message(content, acc) do
    chunk_size = min(@telegram_limit, String.length(content))
    {chunk, rest} = String.split_at(content, chunk_size)
    do_split_message(rest, [chunk | acc])
  end

  defp fetch_valid_bot_token(config) do
    case Keyword.get(config, :bot_token) do
      token when is_binary(token) ->
        if Regex.match?(@token_pattern, token), do: {:ok, token}, else: {:error, :invalid_token}

      _invalid ->
        {:error, :invalid_token}
    end
  end

  defp merged_config(config) do
    config()
    |> Keyword.merge(normalize_config(config))
  end

  defp runtime_default_provider do
    Application.get_env(:elixir_claw, :default_provider, "openai")
  end

  defp runtime_default_model do
    Application.get_env(:elixir_claw, :default_model)
  end

  defp config do
    Application.get_env(:elixir_claw, __MODULE__, [])
  end

  defp normalize_config(config) when is_list(config), do: config
  defp normalize_config(config) when is_map(config), do: Map.to_list(config)
  defp normalize_config(_config), do: []

  defp fetch_chat_id(update) do
    case get_path(update, [:message, :chat, :id]) do
      chat_id when is_integer(chat_id) -> {:ok, chat_id}
      _missing -> {:error, :invalid_update}
    end
  end

  defp fetch_chat_type(update) do
    case get_path(update, [:message, :chat, :type]) do
      "private" -> {:ok, "private"}
      type when is_binary(type) -> {:error, :unsupported_chat_type}
      _missing -> {:error, :invalid_update}
    end
  end

  defp fetch_text(update) do
    case get_path(update, [:message, :text]) do
      text when is_binary(text) -> {:ok, text}
      _missing -> {:error, :invalid_update}
    end
  end

  defp fetch_date(update) do
    case get_path(update, [:message, :date]) do
      date when is_integer(date) -> date
      _missing -> nil
    end
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()
  defp parse_timestamp(unix), do: DateTime.from_unix!(unix)

  defp get_path(data, []), do: data

  defp get_path(data, [key | rest]) when is_map(data) do
    value = Map.get(data, key, Map.get(data, Atom.to_string(key)))

    case value do
      nil -> nil
      next -> get_path(next, rest)
    end
  end

  defp get_path(_data, _path), do: nil

  defp command_for("/start"), do: :start
  defp command_for("/help"), do: :help
  defp command_for("/new"), do: :new
  defp command_for("/approve"), do: {:approve, []}
  defp command_for("/approve " <> tools), do: {:approve, parse_tool_names(tools)}
  defp command_for(_text), do: nil

  defp parse_tool_names(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp approval_message(tool_names) do
    "Approved tools: #{Enum.join(tool_names, ", ")}"
  end

  defp log_incoming(chat_id, content) do
    Logger.debug(fn ->
      preview = content |> String.slice(0, 50) |> Kernel.||("")
      "Telegram chat #{chat_id} incoming: #{preview}"
    end)
  end

  defp log_polling_result(%Telegex.RequestError{reason: :timeout}) do
    Logger.debug("Telegram long polling timed out; restarting poll loop")
  end

  defp log_polling_result(reason) do
    Logger.warning("Telegram polling failed: #{inspect(reason)}")
  end

  defp topic(session_id), do: "session:#{session_id}"
end
