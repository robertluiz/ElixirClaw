defmodule ElixirClaw.Agent.ContextBuilder do
  @moduledoc """
  Builds provider context messages from system prompt, skills, history, and user input.
  """

  alias ElixirClaw.Agent.TaskAgent
  alias ElixirClaw.Agent.CapabilityInventory
  alias ElixirClaw.Types.{Message, Session}

  @summary_marker "[Earlier conversation summarized]"
  @default_max_tokens 4096
  @default_skill_token_budget 1000
  @default_task_agent_token_budget 1000
  @sensitive_assignment_pattern ~r/((?:api_key|token|secret|password)\s*[:=]\s*)([^\s]+)/i
  @api_key_pattern ~r/\b(?:sk|rk)-[A-Za-z0-9\-_]+\b/
  @bearer_token_pattern ~r/\bBearer\s+[A-Za-z0-9\._\-]{10,}\b/i

  @type context_message :: map()

  @spec build_context(Session.t() | [map() | Message.t()], [String.t()], keyword()) ::
          {[context_message()],
           %{
             token_count: non_neg_integer(),
             messages_included: non_neg_integer(),
             messages_dropped: non_neg_integer()
           }}
  def build_context(session_or_messages, skills, opts \\ [])
      when is_list(skills) and is_list(opts) do
    system_prompt = Keyword.get(opts, :system_prompt)

    user_message =
      Keyword.get(opts, :user_message, "") |> sanitize_user_content() |> wrap_user_input()

    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    skill_token_budget = Keyword.get(opts, :skill_token_budget, @default_skill_token_budget)

    task_agent_token_budget =
      Keyword.get(opts, :task_agent_token_budget, @default_task_agent_token_budget)

    system_messages =
      build_system_messages(
        session_or_messages,
        system_prompt,
        skills,
        skill_token_budget,
        task_agent_token_budget
      )

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
     %{
       token_count: token_count,
       messages_included: length(messages),
       messages_dropped: dropped_count
     }}
  end

  @media_token_baseline 85

  @spec estimate_tokens(String.t() | [map()] | nil) :: pos_integer()
  def estimate_tokens(text) when is_binary(text), do: max(1, div(String.length(text), 4))

  def estimate_tokens(content) when is_list(content) do
    content
    |> Enum.reduce(0, fn
      %{"type" => "text", "text" => text}, total when is_binary(text) ->
        total + estimate_tokens(text)

      %{type: "text", text: text}, total when is_binary(text) ->
        total + estimate_tokens(text)

      %{"type" => "image_url"}, total ->
        total + @media_token_baseline

      %{type: "image_url"}, total ->
        total + @media_token_baseline

      _item, total ->
        total
    end)
    |> max(1)
  end

  def estimate_tokens(_text), do: 1

  @spec count_context_tokens([map() | Message.t()]) :: non_neg_integer()
  def count_context_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn message, total -> total + token_count_for(message) end)
  end

  @spec sanitize_user_content(String.t() | [map()] | any()) :: String.t() | [map()]
  def sanitize_user_content(content) when is_list(content) do
    Enum.map(content, &sanitize_content_part/1)
  end

  def sanitize_user_content(content) do
    content
    |> to_string()
    |> String.replace("<|", "")
    |> String.replace("|>", "")
    |> String.replace("[INST]", "")
    |> String.replace("<<SYS>>", "")
    |> String.replace(@sensitive_assignment_pattern, "[REDACTED]")
    |> String.replace(@bearer_token_pattern, "[REDACTED]")
    |> String.replace(@api_key_pattern, "[REDACTED]")
  end

  @spec wrap_user_input(String.t() | [map()] | any()) :: String.t() | [map()]
  def wrap_user_input(content) when is_list(content) do
    Enum.map(content, &wrap_user_content_part/1)
  end

  def wrap_user_input(content), do: wrap_untrusted_content("untrusted_user_input", content)

  @spec extract_text(String.t() | [map()] | any()) :: String.t()
  def extract_text(content) when is_binary(content), do: content

  def extract_text(content) when is_list(content) do
    content
    |> Enum.map(&extract_content_part_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  def extract_text(content), do: content |> to_string() |> String.trim()

  @spec wrap_tool_output(String.t() | any()) :: String.t()
  def wrap_tool_output(content), do: wrap_untrusted_content("untrusted_tool_output", content)

  @spec wrap_memory_summary(String.t() | any()) :: String.t()
  def wrap_memory_summary(content),
    do: wrap_untrusted_content("untrusted_memory_summary", content)

  defp build_system_messages(
         session_or_messages,
         system_prompt,
         skills,
         skill_token_budget,
         task_agent_token_budget
       ) do
    [
      maybe_system_prompt(system_prompt),
      maybe_capability_inventory_message(session_or_messages),
      maybe_orchestrator_memory_message(session_or_messages),
      maybe_task_agent_message(session_or_messages, task_agent_token_budget),
      maybe_task_agent_skills_message(session_or_messages, task_agent_token_budget),
      maybe_skills_message(skills, skill_token_budget)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_system_prompt(prompt) when is_binary(prompt), do: build_message("system", prompt)
  defp maybe_system_prompt(_prompt), do: nil

  defp maybe_orchestrator_memory_message(%Session{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "orchestrator_memory_summary") do
      summary when is_binary(summary) and summary != "" -> build_message("system", summary)
      _ -> nil
    end
  end

  defp maybe_orchestrator_memory_message(_session_or_messages), do: nil

  defp maybe_capability_inventory_message(%Session{metadata: metadata}) when is_map(metadata) do
    context = %{"metadata" => metadata}
    build_message("system", CapabilityInventory.to_system_prompt(context))
  end

  defp maybe_capability_inventory_message(_session_or_messages), do: nil

  defp maybe_task_agent_message(%Session{metadata: metadata}, task_agent_token_budget)
       when is_map(metadata) do
    runtime_agents = Map.get(metadata, "runtime_task_agents", [])

    with task_agent_name when is_binary(task_agent_name) <- Map.get(metadata, "active_task_agent"),
         {:ok, task_agent} <- TaskAgent.fetch(task_agent_name, runtime_agents),
         prompt <- TaskAgent.to_system_prompt(task_agent),
         true <- estimate_tokens(prompt) <= task_agent_token_budget do
      build_message("system", prompt)
    else
      _ -> nil
    end
  end

  defp maybe_task_agent_message(_session_or_messages, _task_agent_token_budget), do: nil

  defp maybe_task_agent_skills_message(%Session{metadata: metadata}, task_agent_token_budget)
       when is_map(metadata) do
    runtime_agents = Map.get(metadata, "runtime_task_agents", [])

    with task_agent_name when is_binary(task_agent_name) <- Map.get(metadata, "active_task_agent"),
         {:ok, task_agent} <- TaskAgent.fetch(task_agent_name, runtime_agents),
         skills when is_list(skills) and skills != [] <- Map.get(task_agent, :skills, []),
         normalized_skills <- normalize_task_agent_skills(skills),
         {composed, _metadata} <-
           ElixirClaw.Skills.Composer.compose(normalized_skills, task_agent_token_budget),
         true <- composed != "" do
      build_message("system", composed)
    else
      _ -> nil
    end
  end

  defp maybe_task_agent_skills_message(_session_or_messages, _task_agent_token_budget), do: nil

  defp normalize_task_agent_skills(skills) do
    Enum.map(skills, fn skill ->
      %{
        name: Map.get(skill, "name", "task-agent-skill"),
        content: Map.get(skill, "content", ""),
        token_estimate: Map.get(skill, "token_estimate", 0),
        priority: 100,
        direct_match?: true
      }
    end)
  end

  defp maybe_skills_message(skills, skill_token_budget) do
    included_skills = take_skills_within_budget(skills, skill_token_budget)

    case included_skills do
      [] -> nil
      _ -> build_message("system", Enum.join(included_skills, "\n\n"))
    end
  end

  defp maybe_user_message(content) when is_list(content), do: [build_message("user", content)]
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
          {[message | acc], tokens + message_tokens, dropped}
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
    wrapped_content = wrap_history_content(role, content)

    message
    |> Map.take([:role, :content, :tool_calls, :tool_call_id])
    |> Map.put(:role, role)
    |> Map.put(:content, wrapped_content)
    |> Map.put(:token_count, estimate_tokens(wrapped_content || ""))
  end

  defp build_message(role, content) do
    %{role: role, content: content, token_count: estimate_tokens(content)}
  end

  defp token_count_for(%Message{content: content}), do: estimate_tokens(content || "")

  defp token_count_for(%{token_count: token_count})
       when is_integer(token_count) and token_count >= 0,
       do: token_count

  defp token_count_for(%{content: content}), do: estimate_tokens(content || "")

  defp wrap_history_content("user", content), do: wrap_user_input(content || "")
  defp wrap_history_content("tool", content), do: wrap_tool_output(content || "")
  defp wrap_history_content(_role, content), do: content || ""

  defp wrap_untrusted_content(tag, content) do
    escaped_content =
      content
      |> to_string()
      |> escape_xml()

    "<#{tag}>#{escaped_content}</#{tag}>"
  end

  defp sanitize_content_part(%{"type" => "text", "text" => text} = part) when is_binary(text) do
    %{part | "text" => sanitize_user_content(text)}
  end

  defp sanitize_content_part(%{type: "text", text: text} = part) when is_binary(text) do
    %{part | text: sanitize_user_content(text)}
  end

  defp sanitize_content_part(part), do: part

  defp wrap_user_content_part(%{"type" => "text", "text" => text} = part) when is_binary(text) do
    %{part | "text" => wrap_untrusted_content("untrusted_user_input", text)}
  end

  defp wrap_user_content_part(%{type: "text", text: text} = part) when is_binary(text) do
    %{part | text: wrap_untrusted_content("untrusted_user_input", text)}
  end

  defp wrap_user_content_part(part), do: part

  defp extract_content_part_text(%{"type" => "text", "text" => text}) when is_binary(text),
    do: text

  defp extract_content_part_text(%{type: "text", text: text}) when is_binary(text), do: text
  defp extract_content_part_text(%{"type" => "image_url"}), do: "[Media attached]"
  defp extract_content_part_text(%{type: "image_url"}), do: "[Media attached]"
  defp extract_content_part_text(_part), do: ""

  defp escape_xml(content) do
    content
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
