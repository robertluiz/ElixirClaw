defmodule ElixirClaw.Agent.Loop do
  @moduledoc false

  require Logger

  import Ecto.Query

  alias ElixirClaw.Agent.ContextBuilder
  alias ElixirClaw.Bus.MessageBus
  alias ElixirClaw.Repo
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
         {:ok, provider} <- resolve_provider(),
         %Session{} = session_with_history <- load_session_history(session),
         {messages, _metadata} <-
           ContextBuilder.build_context(session_with_history, [],
             user_message: sanitized_user_message
           ),
         {:ok, %ProviderResponse{} = response} <-
           run_tool_loop(provider_messages(messages), provider, provider_tools(),
             session: session,
             session_id: session_id,
             model: session.model,
             tool_registry: tool_registry(),
             max_iterations: max_iterations()
           ) do
      normalized_response = normalize_final_response(response)

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
    history =
      from(message in MessageSchema,
        where: message.session_id == ^session.id,
        order_by: [asc: message.inserted_at, asc: message.id]
      )
      |> Repo.all()
      |> Enum.map(&to_context_message/1)

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
          {:ok, output} -> output
          {:error, reason} -> "Tool execution failed: #{inspect(reason)}"
        end

      %{role: "tool", tool_call_id: tool_call.id, content: result}
    end)
  end

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

  defp provider_tools do
    case Registry.to_provider_format(tool_registry()) do
      [] -> []
      tools -> tools
    end
  end

  defp provider_opts(model, []), do: [model: model]
  defp provider_opts(model, tools), do: [model: model, tools: tools]

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

  defp persist_message!(session_id, role, content) do
    attrs = %{
      session_id: session_id,
      role: role,
      content: content,
      token_count: ContextBuilder.estimate_tokens(content)
    }

    %MessageSchema{}
    |> MessageSchema.changeset(attrs)
    |> Repo.insert!()

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

  defp resolve_provider do
    case Keyword.get(config(), :provider) do
      provider when is_atom(provider) -> {:ok, provider}
      _missing_provider -> {:error, :provider_error}
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
