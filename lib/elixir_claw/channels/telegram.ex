defmodule ElixirClaw.Channels.Telegram do
  @moduledoc """
  Telegram channel integration backed by Telegex.
  """

  use GenServer

  require Logger

  alias ElixirClaw.Bus.MessageBus
  alias ElixirClaw.Channel
  alias ElixirClaw.Session.Manager
  alias ElixirClaw.Types.Message

  @behaviour Channel

  @telegram_limit 4096
  @token_pattern ~r/^\d+:[A-Za-z0-9_-]+$/
  @markers ["<|", "|>", "[INST]", "[/INST]", "<<SYS>>", "<</SYS>>"]
  @default_provider "openai"
  @start_message "Welcome to ElixirClaw Telegram. Send a message to begin, or use /help."
  @help_message "Available commands: /start, /help, /new"
  @new_session_message "Started a new session for this chat."

  defmodule API do
    @moduledoc false

    @callback send_message(chat_id :: integer(), text :: String.t()) :: {:ok, term()} | {:error, term()}
  end

  defmodule TelegexAPI do
    @moduledoc false
    @behaviour API

    @impl true
    def send_message(chat_id, text), do: Telegex.send_message(chat_id, text)
  end

  @type state :: %{
          telegex_api: module(),
          chat_sessions: %{optional(integer()) => String.t()},
          session_chats: %{optional(String.t()) => integer()},
          provider: String.t(),
          model: String.t() | nil
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
    {:ok,
     %{
       telegex_api: Keyword.get(config, :telegex_api, TelegexAPI),
       chat_sessions: %{},
       session_chats: %{},
       provider: Keyword.get(config, :provider, @default_provider),
       model: Keyword.get(config, :model)
     }}
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
      :ok -> :ok
      {:error, reason} -> Logger.warning("Telegram send failed for session #{session_id}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(%{type: :error, session_id: session_id, message: content}, state) do
    case deliver_to_session(state, session_id, content) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Telegram error delivery failed for session #{session_id}: #{inspect(reason)}")
    end

    {:noreply, state}
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
              {send_direct_message(next_state, chat_id, @new_session_message, session_id), next_state}

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

              {MessageBus.publish(topic(session_id), payload) |> normalize_publish_result(session_id), next_state}

            {error, next_state} ->
              {error, next_state}
          end
      end
    end
  end

  defp normalize_publish_result(:ok, session_id), do: {:ok, session_id}
  defp normalize_publish_result({:error, reason}, _session_id), do: {:error, reason}

  defp restart_session(chat_id, state) do
    state = maybe_end_existing_session(chat_id, state)
    ensure_session(chat_id, state)
  end

  defp maybe_end_existing_session(chat_id, state) do
    case Map.get(state.chat_sessions, chat_id) do
      nil -> state
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
  defp command_for(_text), do: nil

  defp log_incoming(chat_id, content) do
    Logger.debug(fn ->
      preview = content |> String.slice(0, 50) |> Kernel.||("")
      "Telegram chat #{chat_id} incoming: #{preview}"
    end)
  end

  defp topic(session_id), do: "session:#{session_id}"
end
