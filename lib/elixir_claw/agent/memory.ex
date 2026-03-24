defmodule ElixirClaw.Agent.Memory do
  @moduledoc """
  Consolidates long conversation histories into a single summary message.
  """

  import Ecto.Query

  alias ElixirClaw.Agent.ContextBuilder
  alias ElixirClaw.Repo
  alias ElixirClaw.Schema.{Message, Session}

  @default_threshold trunc(0.6 * 4096)

  @spec consolidate(String.t(), module(), keyword()) ::
          {:ok, %{summary: String.t(), messages_archived: non_neg_integer()}}
          | {:ok, :not_needed}
          | {:error, term()}
  def consolidate(session_id, provider, opts \\ []) when is_binary(session_id) and is_atom(provider) do
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
  def consolidation_needed?(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
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
    summary_token_count = ContextBuilder.estimate_tokens(summary)

    Repo.transaction(fn ->
      from(message in Message, where: message.session_id == ^session_id)
      |> Repo.delete_all()

      %Message{}
      |> Message.changeset(%{
        session_id: session_id,
        role: "system",
        content: summary,
        token_count: summary_token_count
      })
      |> Repo.insert!()

      %{summary: summary, messages_archived: archived_count}
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_session_messages(session_id) do
    from(message in Message,
      where: message.session_id == ^session_id,
      order_by: [asc: message.inserted_at, asc: fragment("rowid")]
    )
    |> Repo.all()
  end

  defp total_token_count(session_id) do
    from(message in Message,
      where: message.session_id == ^session_id,
      select: sum(message.token_count)
    )
    |> Repo.one()
    |> case do
      nil -> 0
      total -> total
    end
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
