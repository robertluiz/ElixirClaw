defmodule ElixirClaw.Agent.Memory do
  @moduledoc """
  Consolidates long conversation histories into a single summary message.
  """

  alias ElixirClaw.Agent.ContextBuilder
  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.{Message, Session}

  @default_threshold trunc(0.6 * 4096)

  @spec consolidate(String.t(), module(), keyword()) ::
          {:ok, %{summary: String.t(), messages_archived: non_neg_integer()}}
          | {:ok, :not_needed}
          | {:error, term()}
  def consolidate(session_id, provider, opts \\ [])
      when is_binary(session_id) and is_atom(provider) do
    with %Session{} <- Repo.get(Session, session_id),
         true <- consolidation_needed?(session_id, opts),
         messages when is_list(messages) <- list_session_messages(session_id),
         {:ok, summary} <- summarize(messages, provider),
         {:ok, result} <- replace_messages(session_id, messages, summary) do
      {:ok, result}
    else
      nil -> {:error, :session_not_found}
      false -> {:ok, :not_needed}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec consolidation_needed?(String.t(), keyword()) :: boolean()
  def consolidation_needed?(session_id, opts \\ [])
      when is_binary(session_id) and is_list(opts) do
    session_id
    |> total_token_count()
    |> Kernel.>(threshold(opts))
  end

  defp summarize(messages, provider) do
    prompt =
      messages
      |> Enum.map_join("\n", fn message -> "#{message.role}: #{message.content}" end)
      |> then(&[%{role: "user", content: "Summarize this conversation:\n" <> &1}])

    with {:ok, response} <- provider.chat(prompt, []),
         summary when is_binary(summary) <- extract_summary(response) do
      {:ok, summary}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_summary_response}
    end
  end

  defp replace_messages(session_id, messages, summary) do
    archived_count = length(messages)
    wrapped_summary = ContextBuilder.wrap_memory_summary(summary)
    summary_token_count = ContextBuilder.estimate_tokens(wrapped_summary)

    summary_message = %Message{
      id: Ecto.UUID.generate(),
      session_id: session_id,
      role: "assistant",
      content: wrapped_summary,
      token_count: summary_token_count,
      inserted_at: DateTime.utc_now() |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)
    }

    case Repo.replace_session_messages(session_id, [summary_message]) do
      {:ok, _messages} -> {:ok, %{summary: summary, messages_archived: archived_count}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_session_messages(session_id) do
    Repo.list_session_messages(session_id)
  end

  defp total_token_count(session_id) do
    Repo.sum_session_message_tokens(session_id)
  end

  defp threshold(opts) do
    opts
    |> Keyword.get_lazy(:threshold, fn ->
      :elixir_claw
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:threshold, @default_threshold)
    end)
  end

  defp extract_summary(%{content: content}) when is_binary(content), do: content
  defp extract_summary(%{"content" => content}) when is_binary(content), do: content
  defp extract_summary(_response), do: nil
end
