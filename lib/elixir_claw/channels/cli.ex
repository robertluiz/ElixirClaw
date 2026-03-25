defmodule ElixirClaw.Channels.CLI do
  @moduledoc """
  Line-oriented CLI channel with streaming output and lightweight `/commands`.
  """

  use GenServer

  @behaviour ElixirClaw.Channel

  alias ElixirClaw.Bus.MessageBus
  alias ElixirClaw.Agent.TaskAgent
  alias ElixirClaw.Repo
  alias ElixirClaw.Session.Manager
  alias ElixirClaw.Types.{Message, Session, TokenUsage}

  @prompt "elixir_claw> "
  @injection_markers ["<|", "|>", "[INST]", "[/INST]", "<<SYS>>", "<</SYS>>"]
  @sensitive_assignment_pattern ~r/((?:api_key|token|secret|password)\s*[:=]\s*)([^\s]+)/i
  @api_key_pattern ~r/\b(?:sk|rk)-[A-Za-z0-9\-_]+\b/

  @type command_result ::
          {:ok, Message.t()}
          | {:help, String.t()}
          | {:session, String.t()}
          | {:task_agents, String.t()}
          | {:approved_tools, [String.t()]}
          | {:active_task_agent, String.t() | :none}
          | {:task_agent_created, String.t()}
          | :new_session
          | :quit
          | {:switch_model, String.t()}
          | {:error, term()}

  @impl true
  def start_link(config \\ %{})
  def start_link(config) when is_list(config), do: start_link(Enum.into(config, %{}))

  def start_link(config) when is_map(config) do
    GenServer.start_link(__MODULE__, config, name: Map.get(config, :name))
  end

  @impl true
  def send_message(_channel_pid, _session_id, payload) do
    payload
    |> format_output()
    |> write_output()

    :ok
  end

  @impl true
  @spec handle_incoming(term()) :: command_result()
  def handle_incoming(raw_message) do
    raw_text = extract_text(raw_message)
    session_id = extract_session_id(raw_message)
    session_manager = extract_session_manager(raw_message)

    normalized_text =
      raw_text
      |> normalize_multiline()
      |> sanitize_input()

    case normalized_text do
      "" ->
        {:error, :empty_input}

      "/help" ->
        {:help, help_text()}

      "/new" ->
        :new_session

      "/quit" ->
        :quit

      "/exit" ->
        :quit

      "/model" ->
        {:error, :missing_model_name}

      "/session" ->
        session_info(session_id, session_manager)

      "/agents" ->
        {:task_agents, task_agents_text()}

      "/agent" ->
        active_task_agent_result(session_id, session_manager)

      "/approve" ->
        {:error, :missing_tool_names}

      _ ->
        cond do
          String.starts_with?(normalized_text, "/model ") ->
            normalized_text
            |> String.replace_prefix("/model ", "")
            |> String.trim()
            |> switch_model_result()

          String.starts_with?(normalized_text, "/approve ") ->
            normalized_text
            |> String.replace_prefix("/approve ", "")
            |> String.trim()
            |> approve_tools_result(session_id, session_manager)

          String.starts_with?(normalized_text, "/agent ") ->
            normalized_text
            |> String.replace_prefix("/agent ", "")
            |> String.trim()
            |> task_agent_result(session_id, session_manager)

          true ->
            {:ok,
             %Message{
               role: "user",
               content: normalized_text,
               timestamp: DateTime.utc_now()
             }}
        end
    end
  end

  @impl true
  def sanitize_input(raw) when is_binary(raw) do
    Enum.reduce(@injection_markers, raw, fn marker, acc -> String.replace(acc, marker, " ") end)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def sanitize_input(raw), do: raw |> to_string() |> sanitize_input()

  @impl true
  def init(config) do
    topics = Map.get(config, :topics, [])
    Enum.each(topics, &MessageBus.subscribe/1)

    state = %{
      device: Map.get(config, :device, :stdio),
      prompt?: Map.get(config, :prompt?, true),
      on_input: Map.get(config, :on_input),
      session_id: Map.get(config, :session_id),
      session_manager: Map.get(config, :session_manager, Manager),
      reader_fun: Map.get(config, :reader_fun, &:io.get_line(&1, "")),
      topics: topics,
      reader_task: nil
    }

    if state.prompt?, do: print_prompt()

    {:ok, start_reader(state)}
  end

  @impl true
  def handle_info({:cli_input, :eof}, state), do: {:stop, :normal, %{state | reader_task: nil}}

  def handle_info({:cli_input, {:error, reason}}, state) do
    send_message(self(), state.session_id || "cli", %{type: :error, content: inspect(reason)})
    {:stop, reason, %{state | reader_task: nil}}
  end

  def handle_info({:cli_input, line}, state) when is_binary(line) do
    raw_message = %{
      text: line,
      session_id: state.session_id,
      session_manager: state.session_manager
    }

    result = handle_incoming(raw_message)
    dispatch_input_result(result, state)
  end

  def handle_info(%{type: _type} = payload, state) do
    send_message(self(), state.session_id || "cli", payload)

    if Map.get(payload, :type) in [:complete, :error, :outgoing_message] and state.prompt? do
      print_prompt()
    end

    {:noreply, state}
  end

  def handle_info(%{"type" => type} = payload, state) do
    handle_info(Map.put(payload, :type, type), state)
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_reader(state) do
    server = self()

    task =
      Task.async(fn ->
        reader_loop(server, state.device, state.reader_fun)
      end)

    %{state | reader_task: task}
  end

  defp reader_loop(server, device, reader_fun) do
    case reader_fun.(device) do
      :eof ->
        send(server, {:cli_input, :eof})

      {:error, _reason} = error ->
        send(server, {:cli_input, error})

      data when is_binary(data) ->
        send(server, {:cli_input, String.trim_trailing(data, "\n")})
        reader_loop(server, device, reader_fun)
    end
  end

  defp dispatch_input_result({:ok, %Message{} = message} = result, state) do
    maybe_dispatch_input(state.on_input, result)

    MessageBus.publish("channel:cli", %{type: :incoming_message, content: message.content})

    if state.prompt?, do: print_prompt()
    {:noreply, state}
  end

  defp dispatch_input_result({:help, text} = result, state) do
    maybe_dispatch_input(state.on_input, result)
    send_message(self(), state.session_id || "cli", text)
    if state.prompt?, do: print_prompt()
    {:noreply, state}
  end

  defp dispatch_input_result({:session, text} = result, state) do
    maybe_dispatch_input(state.on_input, result)
    send_message(self(), state.session_id || "cli", text)
    if state.prompt?, do: print_prompt()
    {:noreply, state}
  end

  defp dispatch_input_result({:task_agents, text} = result, state) do
    maybe_dispatch_input(state.on_input, result)
    send_message(self(), state.session_id || "cli", text)
    if state.prompt?, do: print_prompt()
    {:noreply, state}
  end

  defp dispatch_input_result({:active_task_agent, task_agent_name} = result, state) do
    maybe_dispatch_input(state.on_input, result)

    message =
      case task_agent_name do
        :none -> "Task agent disabled"
        name -> "Active task agent: #{name}"
      end

    send_message(self(), state.session_id || "cli", message)
    if state.prompt?, do: print_prompt()
    {:noreply, state}
  end

  defp dispatch_input_result({:task_agent_created, task_agent_name} = result, state) do
    maybe_dispatch_input(state.on_input, result)
    send_message(self(), state.session_id || "cli", "Created task agent: #{task_agent_name}")
    if state.prompt?, do: print_prompt()
    {:noreply, state}
  end

  defp dispatch_input_result({:approved_tools, tools} = result, state) do
    maybe_dispatch_input(state.on_input, result)
    send_message(self(), state.session_id || "cli", "Approved tools: #{Enum.join(tools, ", ")}")
    if state.prompt?, do: print_prompt()
    {:noreply, state}
  end

  defp dispatch_input_result(:new_session = result, state) do
    maybe_dispatch_input(state.on_input, result)
    if state.prompt?, do: print_prompt()
    {:noreply, state}
  end

  defp dispatch_input_result({:switch_model, _name} = result, state) do
    maybe_dispatch_input(state.on_input, result)
    if state.prompt?, do: print_prompt()
    {:noreply, state}
  end

  defp dispatch_input_result(:quit = result, state) do
    maybe_dispatch_input(state.on_input, result)
    send_message(self(), state.session_id || "cli", "Goodbye!")
    {:stop, :normal, state}
  end

  defp dispatch_input_result({:error, reason} = result, state) do
    maybe_dispatch_input(state.on_input, result)
    send_message(self(), state.session_id || "cli", %{type: :error, content: inspect(reason)})
    if state.prompt?, do: print_prompt()
    {:noreply, state}
  end

  defp maybe_dispatch_input(nil, _result), do: :ok
  defp maybe_dispatch_input(fun, result) when is_function(fun, 1), do: fun.(result)

  defp session_info(nil, _session_manager), do: {:error, :missing_session_id}

  defp session_info(session_id, session_manager) do
    case session_manager.get_session(session_id) do
      {:ok, %Session{} = session} ->
        {:session, format_session_info(session, count_messages(session_id))}

      {:error, :not_found} ->
        {:error, :session_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_session_info(%Session{} = session, message_count) do
    task_agent_fragment =
      case Map.get(session.metadata || %{}, "active_task_agent") do
        nil -> []
        task_agent_name -> ["task agent: #{task_agent_name}"]
      end

    [
      "session: #{session.id}",
      "channel: #{session.channel}",
      "provider: #{session.provider}",
      "model: #{session.model || "n/a"}",
      "messages: #{message_count}",
      "tokens: #{session.token_count_in} in / #{session.token_count_out} out"
    ]
    |> Kernel.++(task_agent_fragment)
    |> Enum.join(" | ")
  end

  defp count_messages(session_id) do
    Repo.count_session_messages(session_id)
  end

  defp switch_model_result(""), do: {:error, :missing_model_name}
  defp switch_model_result(name), do: {:switch_model, name}

  defp approve_tools_result(_tool_names, nil, _session_manager), do: {:error, :missing_session_id}

  defp approve_tools_result("", _session_id, _session_manager), do: {:error, :missing_tool_names}

  defp approve_tools_result(tool_names, session_id, session_manager) do
    parsed_tool_names =
      tool_names
      |> String.split(~r/\s+/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    cond do
      is_nil(session_id) ->
        {:error, :missing_session_id}

      parsed_tool_names == [] ->
        {:error, :missing_tool_names}

      session_manager.approve_tools(session_id, parsed_tool_names) == :ok ->
        {:approved_tools, parsed_tool_names}

      true ->
        {:error, :approval_failed}
    end
  end

  defp active_task_agent_result(nil, _session_manager), do: {:error, :missing_session_id}

  defp active_task_agent_result(session_id, session_manager) do
    case session_manager.get_session(session_id) do
      {:ok, %Session{metadata: metadata}} ->
        {:active_task_agent, Map.get(metadata || %{}, "active_task_agent", :none)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp task_agent_result("", _session_id, _session_manager), do: {:error, :missing_task_agent_name}
  defp task_agent_result(_task_agent_name, nil, _session_manager), do: {:error, :missing_session_id}

  defp task_agent_result("create " <> args, session_id, session_manager) do
    create_task_agent_result(args, session_id, session_manager)
  end

  defp task_agent_result("off", session_id, session_manager) do
    case session_manager.clear_task_agent(session_id) do
      :ok -> {:active_task_agent, :none}
      {:error, reason} -> {:error, reason}
    end
  end

  defp task_agent_result(task_agent_name, session_id, session_manager) do
    case session_manager.set_task_agent(session_id, task_agent_name) do
      :ok -> {:active_task_agent, task_agent_name}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_task_agent_result(args, session_id, session_manager) do
    case parse_task_agent_create_args(args) do
      {:ok, params} ->
        with {:ok, task_agent_name} <- session_manager.create_task_agent(session_id, params),
             :ok <- maybe_activate_created_task_agent(params, session_id, session_manager, task_agent_name) do
          {:task_agent_created, task_agent_name}
        else
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_activate_created_task_agent(%{"activate" => true}, session_id, session_manager, task_agent_name),
    do: session_manager.set_task_agent(session_id, task_agent_name)

  defp maybe_activate_created_task_agent(_params, _session_id, _session_manager, _task_agent_name), do: :ok

  defp parse_task_agent_create_args(args) do
    tokens = String.split(args, ~r/\s+/, trim: true)

    case tokens do
      [name | rest] when name != "" -> {:ok, build_task_agent_create_params(name, rest)}
      _ -> {:error, :missing_task_agent_name}
    end
  end

  defp build_task_agent_create_params(name, tokens) do
    {params, current_key} =
      Enum.reduce(tokens, {%{"name" => name, "tasks" => []}, nil}, fn token, {acc, key} ->
        cond do
          token == "--activate" ->
            {Map.put(acc, "activate", true), nil}

          String.starts_with?(token, "--") ->
            {acc, String.replace_prefix(token, "--", "")}

          key in ["description", "prompt", "model", "tier", "provider"] ->
            mapped_key = cli_create_key(key)
            new_value = [Map.get(acc, mapped_key), token] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
            {Map.put(acc, mapped_key, new_value), key}

          key == "tasks" ->
            tasks = String.split(token, ",", trim: true) |> Enum.map(&String.trim/1)
            {Map.put(acc, "tasks", tasks), nil}

          key == "skill" ->
            skills = Map.get(acc, "skills", []) ++ [%{"name" => token, "content" => "Skill #{token} attached to task agent #{name}."}]
            {Map.put(acc, "skills", skills), nil}

          key == "mcp" ->
            mcps = Map.get(acc, "mcp_servers", []) ++ [token]
            {Map.put(acc, "mcp_servers", mcps), nil}

          true ->
            {acc, key}
        end
      end)

    _ = current_key

    params
    |> Map.update("tasks", [], &Enum.reject(&1, fn task -> task == "" end))
    |> Map.put_new("description", "Runtime task agent #{name}")
    |> Map.put_new("system_prompt", "Execute the specialized workflow for #{name}.")
  end

  defp cli_create_key("prompt"), do: "system_prompt"
  defp cli_create_key("tier"), do: "model_tier"
  defp cli_create_key(other), do: other

  defp extract_text(%{text: text}) when is_binary(text), do: text
  defp extract_text(%{"text" => text}) when is_binary(text), do: text
  defp extract_text(text) when is_binary(text), do: text
  defp extract_text(other), do: to_string(other)

  defp extract_session_id(%{session_id: session_id}) when is_binary(session_id), do: session_id

  defp extract_session_id(%{"session_id" => session_id}) when is_binary(session_id),
    do: session_id

  defp extract_session_id(_raw), do: nil

  defp extract_session_manager(%{session_manager: manager}) when is_atom(manager), do: manager
  defp extract_session_manager(%{"session_manager" => manager}) when is_atom(manager), do: manager
  defp extract_session_manager(_raw), do: Manager

  defp normalize_multiline(text) do
    text
    |> String.replace("\\\n", " ")
    |> String.trim()
  end

  defp help_text do
    [
      "Available commands:",
      "/help - show this help",
      "/new - start a new session",
      "/quit - exit the CLI",
      "/exit - exit the CLI",
      "/model <name> - switch the active model",
      "/session - show current session info",
      "/agents - list specialized task agents",
      "/agent - show the current specialized task agent",
      "/agent <name> - activate a specialized task agent",
      "/agent create <name> [--description ...] [--prompt ...] [--tasks a,b] [--model ...] [--tier cheap|standard|powerful] [--skill skill-name] [--mcp server] [--activate] - create a runtime task agent",
      "/agent off - disable the specialized task agent",
      "/approve <tool...> - approve privileged tools for the current session"
    ]
    |> Enum.join("\n")
  end

  defp task_agents_text do
    ["Available specialized task agents:" | Enum.map(TaskAgent.all(), &"- #{&1.name}: #{&1.description}")]
    |> Enum.join("\n")
  end

  defp format_output(%{type: :stream_chunk} = payload) do
    %{text: redact_text(Map.get(payload, :chunk, "")), newline?: false}
  end

  defp format_output(%{type: :complete} = payload) do
    text = redact_text(Map.get(payload, :content, "")) <> usage_suffix(payload)
    %{text: text, newline?: true}
  end

  defp format_output(%{type: :error} = payload) do
    %{text: colorize(redact_text(Map.get(payload, :content, "")), :red), newline?: true}
  end

  defp format_output(%{content: content}) when is_binary(content) do
    %{text: redact_text(content), newline?: true}
  end

  defp format_output(content) when is_binary(content) do
    %{text: redact_text(content), newline?: true}
  end

  defp write_output(%{text: text, newline?: true}), do: IO.write(text <> "\n")
  defp write_output(%{text: text, newline?: false}), do: IO.write(text)

  defp usage_suffix(payload) do
    case extract_usage(payload) do
      %TokenUsage{input: input, output: output} -> " [tokens: #{input} in / #{output} out]"
      %{input: input, output: output} -> " [tokens: #{input} in / #{output} out]"
      _ -> ""
    end
  end

  defp extract_usage(%{metadata: %{usage: usage}}), do: usage
  defp extract_usage(%{"metadata" => %{"usage" => usage}}), do: usage
  defp extract_usage(%{token_usage: usage}), do: usage
  defp extract_usage(_payload), do: nil

  defp redact_text(text) when is_binary(text) do
    text
    |> String.replace(@sensitive_assignment_pattern, "\\1[REDACTED]")
    |> String.replace(@api_key_pattern, "[REDACTED]")
  end

  defp colorize(text, color) do
    if IO.ANSI.enabled?() do
      [color, text]
      |> IO.ANSI.format()
      |> IO.iodata_to_binary()
    else
      text
    end
  end

  defp print_prompt do
    IO.write(colorize(@prompt, :green))
  end
end
