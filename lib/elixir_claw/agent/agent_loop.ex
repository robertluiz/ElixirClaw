defmodule ElixirClaw.Agent.Loop do
  @moduledoc false

  require Logger

  alias ElixirClaw.Agent.ContextBuilder
  alias ElixirClaw.Bus.MessageBus
  alias ElixirClaw.Providers
  alias ElixirClaw.Repo
  alias ElixirClaw.Security.Canary
  alias ElixirClaw.Schema.Message, as: MessageSchema
  alias ElixirClaw.Session.Manager
  alias ElixirClaw.Tools.Registry
  alias ElixirClaw.Types.{Message, ProviderResponse, Session, TokenUsage}

  @default_max_iterations 10
  @generic_error_message "An error occurred. Please try again."
  @tool_limit_message "Tool call limit reached."

  @type result :: {:ok, ProviderResponse.t()} | {:error, :not_found | :provider_error}

  @spec process_message(String.t(), String.t()) :: result()
  def process_message(session_id, user_message_text)
      when is_binary(session_id) and is_binary(user_message_text) do
    sanitized_user_message = ContextBuilder.sanitize_user_content(user_message_text)

    with {:ok, %Session{} = session} <- Manager.get_session(session_id),
         execution_profile = execution_profile(session),
         {:ok, provider} <- resolve_provider(session, execution_profile),
         %Session{} = session_with_history <- load_session_history(session),
         {messages, _metadata} <-
           ContextBuilder.build_context(session_with_history, [],
             system_prompt: Canary.system_prompt(session_id),
             user_message: sanitized_user_message
           ),
         {:ok, %ProviderResponse{} = response} <-
           run_tool_loop(provider_messages(messages), provider, provider_tools(session),
             session: session,
             session_id: session_id,
             model: execution_profile.model,
             tool_registry: tool_registry(),
             max_iterations: max_iterations()
           ) do
      normalized_response = response |> normalize_final_response() |> protect_response(session_id)

      persist_message!(session_id, "user", sanitized_user_message)
      persist_message!(session_id, "assistant", normalized_response.content)
      publish_outgoing_message(session_id, normalized_response.content)

      {:ok, normalized_response}
    else
      {:error, :not_found} = error ->
        error

      {:error, :provider_error} = error ->
        persist_message!(session_id, "user", sanitized_user_message)
        publish_error_message(session_id)
        error
    end
  end

  defp run_tool_loop(messages, provider, tools, opts, iteration \\ 0)

  defp run_tool_loop(messages, provider, tools, opts, iteration) do
    provider_name = provider_name(provider, opts[:session], opts[:model])
    model = opts[:model]

    Logger.info(
      "Attempting provider call for session #{opts[:session_id]} with provider=#{provider_name} model=#{inspect(model)}"
    )

    case provider.chat(messages, provider_opts(opts[:model], tools)) do
      {:ok, %ProviderResponse{} = response} ->
        token_usage = normalize_token_usage(response.token_usage)
        record_token_usage(opts[:session_id], token_usage)

        case response.tool_calls do
          tool_calls when is_list(tool_calls) and tool_calls != [] ->
            if iteration >= opts[:max_iterations] do
              {:ok,
               %ProviderResponse{
                 response
                 | content: response.content || @tool_limit_message,
                   tool_calls: nil
               }}
            else
              assistant_message = %{
                role: "assistant",
                content: response.content || "",
                tool_calls: tool_calls
              }

              tool_messages = execute_tool_calls(tool_calls, opts[:session], opts[:tool_registry])
              index_tool_messages(opts[:session].id, tool_calls, tool_messages)

              run_tool_loop(
                messages ++ [assistant_message] ++ tool_messages,
                provider,
                tools,
                opts,
                iteration + 1
              )
            end

          _no_tool_calls ->
            {:ok, response}
        end

      {:error, reason} ->
        Logger.warning(
          "Provider call failed for session #{opts[:session_id]}: #{inspect(reason)}"
        )

        {:error, :provider_error}
    end
  end

  defp load_session_history(%Session{} = session) do
    history = Repo.list_session_messages(session.id) |> Enum.map(&to_context_message/1)

    %{session | messages: history}
  end

  defp to_context_message(%MessageSchema{} = message) do
    %Message{
      role: message.role,
      content: message.content,
      tool_calls: message.tool_calls,
      tool_call_id: message.tool_call_id,
      token_count: message.token_count,
      timestamp: message.inserted_at
    }
  end

  defp execute_tool_calls(tool_calls, %Session{} = session, tool_registry) do
    Enum.map(tool_calls, fn tool_call ->
      result =
        case Registry.execute(
               tool_call.name,
               tool_call.arguments,
               tool_context(session),
               tool_registry
             ) do
          {:ok, output} ->
            output |> ContextBuilder.sanitize_user_content() |> ContextBuilder.wrap_tool_output()

          {:error, {:approval_required, tool_name}} ->
            :ok = Manager.request_tool_approval(session.id, tool_name)

            approval_required_message(tool_name)
            |> ContextBuilder.sanitize_user_content()
            |> ContextBuilder.wrap_tool_output()

          {:error, reason} ->
            "Tool execution failed: #{inspect(reason)}"
            |> ContextBuilder.sanitize_user_content()
            |> ContextBuilder.wrap_tool_output()
        end

      %{role: "tool", tool_call_id: tool_call.id, content: result}
    end)
  end

  defp index_tool_messages(session_id, tool_calls, tool_messages)
       when is_binary(session_id) and is_list(tool_calls) and is_list(tool_messages) do
    Enum.zip(tool_calls, tool_messages)
    |> Enum.each(fn {tool_call, tool_message} ->
      ElixirClaw.Agent.MemoryGraphIndexer.index_execution_async(session_id, %{
        name: tool_call.name,
        content: tool_message.content,
        metadata: %{"tool_call_id" => tool_call.id, "arguments" => tool_call.arguments}
      })
    end)
  end

  defp index_tool_messages(_session_id, _tool_calls, _tool_messages), do: :ok

  defp tool_context(%Session{} = session) do
    %{
      "session_id" => session.id,
      "channel" => session.channel,
      "channel_user_id" => session.channel_user_id,
      "provider" => session.provider,
      "model" => session.model,
      "metadata" => session.metadata || %{}
    }
  end

  defp provider_messages(messages) do
    Enum.map(messages, fn message ->
      message
      |> Map.take([:role, :content, :tool_calls, :tool_call_id])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.into(%{})
    end)
  end

  defp provider_tools(%Session{} = session) do
    case Registry.to_provider_format(tool_registry(), tool_context(session)) do
      [] -> []
      tools -> tools
    end
  end

  defp provider_opts(model, []), do: [model: model]
  defp provider_opts(model, tools), do: [model: model, tools: tools]

  defp provider_name(_provider, %Session{provider: provider_name}, _model)
       when is_binary(provider_name) and provider_name != "",
       do: provider_name

  defp provider_name(provider, _session, _model) when is_atom(provider), do: inspect(provider)
  defp provider_name(provider, _session, _model), do: inspect(provider)

  defp record_token_usage(session_id, %TokenUsage{} = token_usage) do
    Logger.info(
      "Session #{session_id}: #{token_usage.input} in / #{token_usage.output} out tokens"
    )

    case Manager.record_call(session_id, token_usage) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to record tokens for session #{session_id}: #{inspect(reason)}")
    end
  end

  defp normalize_token_usage(%TokenUsage{} = token_usage), do: token_usage

  defp normalize_token_usage(token_usage) when is_map(token_usage) do
    input = Map.get(token_usage, :input, Map.get(token_usage, "input", 0))
    output = Map.get(token_usage, :output, Map.get(token_usage, "output", 0))

    %TokenUsage{input: input, output: output, total: input + output}
  end

  defp normalize_token_usage(_token_usage), do: %TokenUsage{}

  defp normalize_final_response(%ProviderResponse{} = response) do
    %ProviderResponse{response | content: response.content || ""}
  end

  defp protect_response(%ProviderResponse{} = response, session_id) do
    if Canary.leaked?(response.content, session_id) do
      %ProviderResponse{response | content: Canary.blocked_message(), tool_calls: nil}
    else
      case Manager.get_session(session_id) do
        {:ok, %Session{metadata: %{"pending_tool_approvals" => [tool_name | _]}}}
        when is_binary(tool_name) ->
          %ProviderResponse{
            response
            | content: approval_required_message(tool_name),
              tool_calls: nil
          }

        _other ->
          response
      end
    end
  end

  defp approval_required_message(tool_name) do
    "Approval required for tool '#{tool_name}'. Run /approve #{tool_name} to continue."
  end

  defp persist_message!(session_id, role, content) do
    attrs = %{
      session_id: session_id,
      role: role,
      content: content,
      token_count: ContextBuilder.estimate_tokens(content)
    }

    _message = Repo.insert_message(attrs)

    :ok
  end

  defp publish_outgoing_message(session_id, content) do
    MessageBus.publish(topic(session_id), %{
      type: :outgoing_message,
      session_id: session_id,
      content: content
    })
  end

  defp publish_error_message(session_id) do
    MessageBus.publish(topic(session_id), %{
      type: :error,
      session_id: session_id,
      message: @generic_error_message
    })
  end

  defp resolve_provider(%Session{} = session, execution_profile) do
    case Keyword.get(config(), :provider) do
      nil -> resolve_session_provider(execution_profile.provider || session.provider)
      provider when is_atom(provider) -> {:ok, provider}
      _invalid_override -> {:error, :provider_error}
    end
  end

  defp execution_profile(%Session{} = session) do
    case Manager.effective_task_agent(session) do
      {:ok, task_agent} ->
        %{
          provider: task_agent.provider || session.provider,
          model: task_agent.model || session.model
        }

      {:error, :unknown_task_agent} ->
        %{provider: session.provider, model: session.model}
    end
  end

  defp resolve_session_provider(provider_name) do
    case Providers.resolve(provider_name) do
      {:ok, provider} -> {:ok, provider}
      {:error, :unknown_provider} -> {:error, :provider_error}
    end
  end

  defp tool_registry do
    Keyword.get(config(), :tool_registry, Registry)
  end

  defp max_iterations do
    Keyword.get(config(), :max_iterations, @default_max_iterations)
  end

  defp config do
    Application.get_env(:elixir_claw, __MODULE__, [])
  end

  defp topic(session_id), do: "session:#{session_id}"
end
