defmodule ElixirClaw.Agent.ContextBuilder do
  @moduledoc """
  Builds provider context messages from system prompt, skills, history, and user input.
  """

  alias ElixirClaw.Types.{Message, Session}

  @summary_marker "[Earlier conversation summarized]"
  @default_max_tokens 4096
  @default_skill_token_budget 1000

  @type context_message :: map()

  @spec build_context(Session.t() | [map() | Message.t()], [String.t()], keyword()) ::
          {[context_message()], %{token_count: non_neg_integer(), messages_included: non_neg_integer(), messages_dropped: non_neg_integer()}}
  def build_context(session_or_messages, skills, opts \\ []) when is_list(skills) and is_list(opts) do
    system_prompt = Keyword.get(opts, :system_prompt)
    user_message = Keyword.get(opts, :user_message, "") |> sanitize_user_content()
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    skill_token_budget = Keyword.get(opts, :skill_token_budget, @default_skill_token_budget)

    system_messages = build_system_messages(system_prompt, skills, skill_token_budget)
    user_messages = maybe_user_message(user_message)

    reserved_tokens = count_context_tokens(system_messages ++ user_messages)
    history_budget = max(max_tokens - reserved_tokens, 0)

    {history_messages, dropped_count} =
      session_or_messages
      |> extract_messages()
      |> select_history_messages(history_budget)

    messages = system_messages ++ history_messages ++ user_messages
    token_count = count_context_tokens(messages)

    {messages,
     %{token_count: token_count, messages_included: length(messages), messages_dropped: dropped_count}}
  end

  @spec estimate_tokens(String.t() | nil) :: pos_integer()
  def estimate_tokens(text) when is_binary(text), do: max(1, div(String.length(text), 4))
  def estimate_tokens(_text), do: 1

  @spec count_context_tokens([map() | Message.t()]) :: non_neg_integer()
  def count_context_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn message, total -> total + token_count_for(message) end)
  end

  @spec sanitize_user_content(String.t() | any()) :: String.t()
  def sanitize_user_content(content) do
    content
    |> to_string()
    |> String.replace("<|", "")
    |> String.replace("|>", "")
    |> String.replace("[INST]", "")
    |> String.replace("<<SYS>>", "")
  end

  defp build_system_messages(system_prompt, skills, skill_token_budget) do
    [maybe_system_prompt(system_prompt), maybe_skills_message(skills, skill_token_budget)]
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_system_prompt(prompt) when is_binary(prompt), do: build_message("system", prompt)
  defp maybe_system_prompt(_prompt), do: nil

  defp maybe_skills_message(skills, skill_token_budget) do
    included_skills = take_skills_within_budget(skills, skill_token_budget)

    case included_skills do
      [] -> nil
      _ -> build_message("system", Enum.join(included_skills, "\n\n"))
    end
  end

  defp maybe_user_message(""), do: [build_message("user", "")]
  defp maybe_user_message(content), do: [build_message("user", content)]

  defp take_skills_within_budget(skills, skill_token_budget) do
    {included_skills, _used_tokens} =
      Enum.reduce_while(skills, {[], 0}, fn skill, {acc, used_tokens} ->
      skill_tokens = estimate_tokens(skill)

      if used_tokens + skill_tokens <= skill_token_budget do
        {:cont, {[skill | acc], used_tokens + skill_tokens}}
      else
        {:halt, {acc, used_tokens}}
      end
    end)

    Enum.reverse(included_skills)
  end

  defp extract_messages(%Session{messages: messages}) when is_list(messages), do: messages
  defp extract_messages(messages) when is_list(messages), do: messages

  defp select_history_messages(messages, history_budget) do
    normalized_messages = Enum.map(messages, &normalize_history_message/1)

    {selected, used_tokens, dropped_count} =
      normalized_messages
      |> Enum.reverse()
      |> Enum.reduce({[], 0, 0}, fn message, {acc, tokens, dropped} ->
        message_tokens = token_count_for(message)

        if tokens + message_tokens <= history_budget do
          {acc ++ [message], tokens + message_tokens, dropped}
        else
          {acc, tokens, dropped + 1}
        end
      end)

    maybe_prepend_summary_marker(selected, used_tokens, dropped_count, history_budget)
  end

  defp maybe_prepend_summary_marker(selected, _used_tokens, 0, _history_budget), do: {selected, 0}

  defp maybe_prepend_summary_marker(selected, used_tokens, dropped_count, history_budget) do
    marker = build_message("system", @summary_marker)
    marker_tokens = token_count_for(marker)

    {trimmed_selected, _trimmed_tokens, final_dropped_count} =
      trim_for_marker(selected, used_tokens, dropped_count, history_budget, marker_tokens)

    {[marker | trimmed_selected], final_dropped_count}
  end

  defp trim_for_marker(selected, used_tokens, dropped_count, history_budget, marker_tokens)
       when used_tokens + marker_tokens <= history_budget do
    {selected, used_tokens, dropped_count}
  end

  defp trim_for_marker([], used_tokens, dropped_count, _history_budget, _marker_tokens) do
    {[], used_tokens, dropped_count}
  end

  defp trim_for_marker(selected, used_tokens, dropped_count, history_budget, marker_tokens) do
    {remaining, [oldest_message]} = Enum.split(selected, length(selected) - 1)
    updated_tokens = used_tokens - token_count_for(oldest_message)

    trim_for_marker(remaining, updated_tokens, dropped_count + 1, history_budget, marker_tokens)
  end

  defp normalize_history_message(%Message{} = message) do
    message
    |> Map.from_struct()
    |> normalize_history_message()
  end

  defp normalize_history_message(%{role: role, content: content} = message) do
    message
    |> Map.take([:role, :content, :tool_calls, :tool_call_id])
    |> Map.put(:role, role)
    |> Map.put(:content, content)
    |> Map.put(:token_count, estimate_tokens(content || ""))
  end

  defp build_message(role, content) do
    %{role: role, content: content, token_count: estimate_tokens(content)}
  end

  defp token_count_for(%Message{content: content}), do: estimate_tokens(content || "")

  defp token_count_for(%{token_count: token_count}) when is_integer(token_count) and token_count >= 0,
    do: token_count

  defp token_count_for(%{content: content}), do: estimate_tokens(content || "")
end
