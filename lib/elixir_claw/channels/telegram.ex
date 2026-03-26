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

    @callback send_photo(chat_id :: integer(), photo :: String.t(), keyword()) ::
                {:ok, term()} | {:error, term()}

    @callback send_audio(chat_id :: integer(), audio :: String.t(), keyword()) ::
                {:ok, term()} | {:error, term()}

    @callback get_file(file_id :: String.t()) :: {:ok, term()} | {:error, term()}

    @callback set_webhook(keyword()) :: {:ok, term()} | {:error, term()}

    @callback delete_webhook(keyword()) :: {:ok, term()} | {:error, term()}

    @callback get_updates(keyword()) :: {:ok, list(term())} | {:error, term()}
    @callback get_me() :: {:ok, term()} | {:error, term()}
  end

  defmodule TelegexAPI do
    @moduledoc false
    @behaviour API

    @impl true
    def send_message(chat_id, text), do: Telegex.send_message(chat_id, text)

    @impl true
    def send_photo(chat_id, photo, opts), do: Telegex.send_photo(chat_id, photo, opts)

    @impl true
    def send_audio(chat_id, audio, opts), do: Telegex.send_audio(chat_id, audio, opts)

    @impl true
    def get_file(file_id), do: Telegex.get_file(file_id)

    @impl true
    def set_webhook(opts), do: Telegex.set_webhook(opts)

    @impl true
    def get_updates(opts), do: Telegex.get_updates(opts)

    @impl true
    def delete_webhook(opts), do: Telegex.delete_webhook(opts)

    @impl true
    def get_me, do: Telegex.get_me()
  end

  defmodule AgentLoop do
    @moduledoc false

    @callback process_message(String.t(), String.t() | [map()]) ::
                {:ok, term()} | {:error, term()}
  end

  defmodule DefaultAgentLoop do
    @moduledoc false
    @behaviour AgentLoop

    @impl true
    def process_message(session_id, content),
      do: AgentLoopModule.process_message(session_id, content)
  end

  @type state :: %{
          config: keyword(),
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
          transport_mode: :polling | :webhook,
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
  @spec send_message(pid(), String.t(), Channel.outbound_payload()) :: :ok | {:error, term()}
  def send_message(channel_pid, session_id, content)
      when is_pid(channel_pid) and is_binary(session_id) and
             (is_binary(content) or is_map(content)) do
    GenServer.call(channel_pid, {:send_message, session_id, content})
  end

  @impl Channel
  @spec handle_incoming(map()) :: {:ok, Message.t()} | {:error, term()}
  def handle_incoming(raw_message) when is_map(raw_message) do
    transcriber =
      Application.get_env(:elixir_claw, __MODULE__, [])
      |> Keyword.get(:audio_transcriber, ElixirClaw.Media.AudioTranscriber.OpenAICompatible)

    with {:ok, "private"} <- fetch_chat_type(raw_message),
         {:ok, content} <- extract_incoming_content(raw_message, transcriber) do
      {:ok,
       %Message{
         role: "user",
         content: content,
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
    normalized_config = normalize_config(config)

    state = %{
      config: normalized_config,
      telegex_api: Keyword.get(config, :telegex_api, TelegexAPI),
      agent_loop: Keyword.get(config, :agent_loop, DefaultAgentLoop),
      audio_transcriber:
        Keyword.get(
          config,
          :audio_transcriber,
          ElixirClaw.Media.AudioTranscriber.OpenAICompatible
        ),
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
      transport_mode: :polling,
      start_polling?: Keyword.get(config, :start_polling, true),
      test_pid: Keyword.get(config, :test_pid)
    }

    :ok = Phoenix.PubSub.subscribe(ElixirClaw.PubSub, telegram_webhook_topic())
    state = maybe_boot_transport(state)

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

  def handle_info({:telegram_webhook_update, update}, state) when is_map(update) do
    {_reply, next_state} = process_update_call(update, state)
    {:noreply, next_state}
  end

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
      {:error, :ignored_media} -> {{:error, :ignored_media}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp normalize_publish_result(:ok, session_id), do: {:ok, session_id}
  defp normalize_publish_result({:error, reason}, _session_id), do: {:error, reason}

  defp maybe_boot_transport(state) do
    allow_test_mocks(state)
    log_bot_ready(state.telegex_api)

    case configure_webhook(state) do
      {:ok, next_state} ->
        next_state

      {:error, reason} ->
        maybe_notify_test_pid(state.test_pid, {:telegram_webhook_fallback, reason})
        boot_polling_fallback(state, reason)
    end
  end

  defp configure_webhook(state) do
    case webhook_config(state) do
      {:ok, webhook_opts} ->
        if Code.ensure_loaded?(ElixirClaw.Channels.Telegram.WebhookServer) and
             function_exported?(ElixirClaw.Channels.Telegram.WebhookServer, :enabled?, 1) and
             not ElixirClaw.Channels.Telegram.WebhookServer.enabled?(state.config) do
          {:error, :webhook_server_disabled}
        else
          webhook_opts = Keyword.put(webhook_opts, :allowed_updates, state.poll_allowed_updates)

          case state.telegex_api.set_webhook(webhook_opts) do
            {:ok, _result} ->
              maybe_notify_test_pid(state.test_pid, {:telegram_webhook_enabled, webhook_opts})
              {:ok, %{state | start_polling?: false, transport_mode: :webhook}}

            {:error, reason} ->
              Logger.warning(
                "Telegram webhook setup failed: #{inspect(reason)}; falling back to polling"
              )

              {:error, reason}
          end
        end

      :disabled ->
        {:error, :webhook_disabled}
    end
  end

  defp boot_polling_fallback(%{start_polling?: true} = state, _reason) do
    maybe_delete_webhook(state.telegex_api)
    schedule_poll(0)
    %{state | transport_mode: :polling}
  end

  defp boot_polling_fallback(state, _reason), do: %{state | transport_mode: :polling}

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

      send(
        server,
        {:telegram_polled, state.poll_offset, state.telegex_api.get_updates(updates_opts)}
      )
    end)

    %{state | poll_inflight?: true}
  end

  defp process_polled_updates(updates, current_offset, state) do
    Enum.reduce(updates, {current_offset, state}, fn update, {offset, acc_state} ->
      next_offset = max(offset, update_id(update) + 1)

      case process_update_call(update, acc_state) do
        {{:error, :ignored_media}, next_state} ->
          {next_offset, next_state}

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

  defp telegram_webhook_topic, do: "channel:telegram:webhook"

  defp maybe_notify_test_pid(nil, _message), do: :ok
  defp maybe_notify_test_pid(pid, message) when is_pid(pid), do: send(pid, message)

  defp webhook_config(state) do
    channel_config = state.config

    enabled? =
      case Keyword.get(channel_config, :webhook_enabled) do
        value when value in [true, false] -> value
        _other -> false
      end

    cond do
      not enabled? ->
        :disabled

      true ->
        url = Keyword.get(channel_config, :webhook_url)
        secret_token = Keyword.get(channel_config, :webhook_secret_token)
        max_connections = Keyword.get(channel_config, :webhook_max_connections)
        ip_address = Keyword.get(channel_config, :webhook_ip_address)
        drop_pending_updates = Keyword.get(channel_config, :webhook_drop_pending_updates)

        if is_binary(url) and String.trim(url) != "" do
          {:ok,
           []
           |> Keyword.put(:url, url)
           |> maybe_put_keyword(:secret_token, secret_token)
           |> maybe_put_keyword(:max_connections, max_connections)
           |> maybe_put_keyword(:ip_address, ip_address)
           |> maybe_put_keyword(:drop_pending_updates, drop_pending_updates)}
        else
          :disabled
        end
    end
  end

  defp update_id(update) when is_map(update) do
    Map.get(update, :update_id, Map.get(update, "update_id", 0)) || 0
  end

  defp deliver_to_session(state, session_id, content) do
    case Map.get(state.session_chats, session_id) do
      nil -> {:error, :unknown_session}
      chat_id -> deliver_content(state, chat_id, content)
    end
  end

  defp send_direct_message(state, chat_id, content, session_id \\ :command_handled) do
    case deliver_content(state, chat_id, content) do
      :ok -> {:ok, session_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver_content(%{telegex_api: api}, chat_id, content) when is_binary(content) do
    deliver_chunks(api, chat_id, split_message(content))
  end

  defp deliver_content(state, chat_id, %{type: :photo, url: url} = payload) when is_binary(url) do
    deliver_media_async(state, fn api ->
      api.send_photo(chat_id, url, media_options(payload, [:caption]))
    end)
  end

  defp deliver_content(state, chat_id, %{type: :audio, url: url} = payload) when is_binary(url) do
    deliver_media_async(state, fn api ->
      api.send_audio(
        chat_id,
        url,
        media_options(payload, [:caption, :duration, :performer, :title])
      )
    end)
  end

  defp deliver_content(_state, _chat_id, _content), do: {:error, :unsupported_content}

  defp deliver_media_async(state, deliver_fun) when is_function(deliver_fun, 1) do
    Task.start(fn ->
      allow_test_mocks(state)

      case deliver_fun.(state.telegex_api) do
        {:ok, _response} ->
          :ok

        {:error, reason} ->
          Logger.warning("Telegram media delivery failed: #{inspect(reason)}")
      end
    end)

    :ok
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

  defp media_options(payload, allowed_keys) do
    Enum.reduce(allowed_keys, [], fn key, acc ->
      case Map.get(payload, key) do
        value when is_binary(value) and value != "" -> [{key, value} | acc]
        value when is_integer(value) and value >= 0 -> [{key, value} | acc]
        _other -> acc
      end
    end)
    |> Enum.reverse()
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

  defp maybe_put_keyword(keyword, _key, nil), do: keyword
  defp maybe_put_keyword(keyword, _key, ""), do: keyword
  defp maybe_put_keyword(keyword, key, value), do: Keyword.put(keyword, key, value)

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
      text when is_binary(text) ->
        {:ok, text}

      _missing ->
        case get_path(update, [:message, :caption]) do
          caption when is_binary(caption) -> {:ok, caption}
          _other -> {:error, :ignored_media}
        end
    end
  end

  defp extract_incoming_content(update, transcriber) do
    cond do
      image_file_id = latest_photo_file_id(update) ->
        caption = update |> fetch_caption() |> sanitize_input()
        {:ok, build_photo_content(image_file_id, caption)}

      audio_file_id = audio_file_id(update) ->
        caption = update |> fetch_caption() |> sanitize_input()
        audio = get_path(update, [:message, :audio]) || %{}

        transcribe_or_fallback(
          transcriber,
          audio_file_id,
          infer_file_name(audio_file_id, Map.get(audio, :title, Map.get(audio, "title")), ".mp3"),
          "audio/mpeg",
          caption,
          Map.get(audio, :duration, Map.get(audio, "duration")),
          Map.get(audio, :performer, Map.get(audio, "performer")),
          Map.get(audio, :title, Map.get(audio, "title"))
        )

      voice_file_id = voice_file_id(update) ->
        voice = get_path(update, [:message, :voice]) || %{}

        transcribe_or_fallback(
          transcriber,
          voice_file_id,
          infer_file_name(voice_file_id, nil, ".ogg"),
          "audio/ogg",
          "",
          Map.get(voice, :duration, Map.get(voice, "duration")),
          nil,
          nil
        )

      true ->
        with {:ok, text} <- fetch_text(update) do
          {:ok, sanitize_input(text)}
        end
    end
  end

  defp fetch_caption(update) do
    case get_path(update, [:message, :caption]) do
      caption when is_binary(caption) -> caption
      _missing -> ""
    end
  end

  defp latest_photo_file_id(update) do
    update
    |> get_path([:message, :photo])
    |> case do
      photos when is_list(photos) and photos != [] ->
        photos
        |> List.last()
        |> then(fn photo -> Map.get(photo, :file_id, Map.get(photo, "file_id")) end)

      _other ->
        nil
    end
  end

  defp audio_file_id(update) do
    case get_path(update, [:message, :audio]) do
      audio when is_map(audio) -> Map.get(audio, :file_id, Map.get(audio, "file_id"))
      _other -> nil
    end
  end

  defp voice_file_id(update) do
    case get_path(update, [:message, :voice]) do
      voice when is_map(voice) -> Map.get(voice, :file_id, Map.get(voice, "file_id"))
      _other -> nil
    end
  end

  defp transcribe_or_fallback(
         transcriber,
         file_id,
         filename,
         content_type,
         caption,
         duration,
         performer,
         title
       ) do
    transcription_opts = [
      caption: caption,
      duration: duration,
      performer: performer,
      title: title,
      filename: filename,
      content_type: content_type
    ]

    case fetch_telegram_file_binary(file_id) do
      {:ok, audio_binary} ->
        case transcriber.transcribe(audio_binary, transcription_opts) do
          {:ok, text} when is_binary(text) and text != "" ->
            {:ok, sanitize_input(text)}

          {:error, :not_configured} ->
            {:ok,
             build_audio_summary(caption, duration, performer, title, :transcriber_not_configured)}

          _other ->
            {:ok, build_audio_summary(caption, duration, performer, title, :transcription_failed)}
        end

      {:error, _reason} ->
        {:ok, build_audio_summary(caption, duration, performer, title, :telegram_download_failed)}
    end
  end

  defp fetch_telegram_file_binary(file_id) do
    case fetch_telegram_file(file_id) do
      {:ok, %{binary: binary}} -> {:ok, binary}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_telegram_file(file_id) do
    api =
      Application.get_env(:elixir_claw, __MODULE__, []) |> Keyword.get(:telegex_api, TelegexAPI)

    req_options = Application.get_env(:elixir_claw, :telegram_req_options, [])
    req_options = Keyword.put_new(req_options, :retry, false)

    with {:ok, file_path} <- fetch_telegram_file_path(api, file_id),
         {:ok, download_url} <- telegram_file_download_url(req_options),
         {:ok, response} <-
           Req.get(Keyword.merge(req_options, url: download_url.(file_path))),
         :ok <- validate_telegram_file_download(response),
         binary when is_binary(binary) <- response.body do
      {:ok, %{binary: binary, file_path: file_path}}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :download_failed}
    end
  end

  defp build_photo_content(file_id, caption) do
    image_part =
      case build_inline_image_part(file_id) do
        {:ok, image_part} -> image_part
        {:error, _reason} -> %{type: "image_url", image_url: %{url: "tg://file/#{file_id}"}}
      end

    case caption do
      text when is_binary(text) and text != "" ->
        [image_part, %{type: "text", text: text}]

      _other ->
        [image_part]
    end
  end

  defp build_inline_image_part(file_id) do
    with {:ok, %{binary: binary, file_path: file_path}} <- fetch_telegram_file(file_id) do
      {:ok,
       %{
         type: "image_url",
         image_url: %{
           url: build_image_data_url(binary, infer_image_content_type(file_path)),
           detail: "auto"
         }
       }}
    end
  end

  defp build_image_data_url(binary, content_type)
       when is_binary(binary) and is_binary(content_type) do
    "data:#{content_type};base64,#{Base.encode64(binary)}"
  end

  defp infer_image_content_type(file_path) when is_binary(file_path) do
    case file_path |> Path.extname() |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      _other -> "image/jpeg"
    end
  end

  defp fetch_telegram_file_path(api, file_id) do
    case api.get_file(file_id) do
      {:ok, %{file_path: file_path}} when is_binary(file_path) -> {:ok, file_path}
      {:ok, %{"file_path" => file_path}} when is_binary(file_path) -> {:ok, file_path}
      {:ok, _other} -> {:error, :missing_file_path}
      {:error, _reason} = error -> error
    end
  end

  defp telegram_file_download_url(req_options) do
    with {:ok, token} <- fetch_telegram_bot_token() do
      base_url =
        req_options
        |> Keyword.get(:base_url, "https://api.telegram.org")
        |> String.trim_trailing("/")

      {:ok,
       fn file_path ->
         "#{base_url}/file/bot#{token}/#{file_path}"
       end}
    end
  end

  defp fetch_telegram_bot_token do
    case Application.get_env(:telegex, :token) || Keyword.get(config(), :bot_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _missing -> {:error, :missing_bot_token}
    end
  end

  defp validate_telegram_file_download(%Req.Response{status: status}) when status in 200..299,
    do: :ok

  defp validate_telegram_file_download(%Req.Response{}), do: {:error, :download_failed}

  defp infer_file_name(file_id, title, extension) do
    base = if is_binary(title) and title != "", do: title, else: file_id
    base <> extension
  end

  defp build_audio_summary(caption, duration, performer, title, reason) do
    [
      caption,
      audio_fallback_notice(reason),
      format_audio_meta("duration", duration),
      format_audio_meta("performer", performer),
      format_audio_meta("title", title)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp audio_fallback_notice(:transcriber_not_configured),
    do: "Audio received, but transcription is not configured for this runtime."

  defp audio_fallback_notice(:telegram_download_failed),
    do: "Audio received, but Telegram file download failed before transcription."

  defp audio_fallback_notice(:transcription_failed),
    do: "Audio received, but transcription failed for this message."

  defp format_audio_meta(_key, nil), do: nil
  defp format_audio_meta(_key, ""), do: nil
  defp format_audio_meta(key, value), do: "#{key}=#{value}"

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
      preview = incoming_preview(content)
      "Telegram chat #{chat_id} incoming: #{preview}"
    end)
  end

  defp incoming_preview(content) when is_binary(content), do: String.slice(content, 0, 50) || ""

  defp incoming_preview(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{text: text} when is_binary(text) -> text
      _other -> "[media]"
    end)
    |> Enum.join(" ")
    |> String.slice(0, 50)
  end

  defp incoming_preview(_content), do: ""

  defp log_polling_result(%Telegex.RequestError{reason: :timeout}) do
    Logger.debug("Telegram long polling timed out; restarting poll loop")
  end

  defp log_polling_result(reason) do
    Logger.warning("Telegram polling failed: #{inspect(reason)}")
  end

  defp topic(session_id), do: "session:#{session_id}"
end
