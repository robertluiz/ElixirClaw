defmodule ElixirClaw.Skills.Matcher do
  @moduledoc """
  Matches skills against a user message using plain string or regex triggers.
  """

  require Logger

  alias ElixirClaw.Skills.Skill

  @spec match_skills(String.t(), [Skill.t() | map()]) :: [Skill.t() | map()]
  def match_skills(user_message, skills) when is_binary(user_message) and is_list(skills) do
    normalized_message = String.downcase(user_message)

    skills
    |> Enum.filter(&skill_matches?(&1, normalized_message))
    |> Enum.sort_by(&Map.get(&1, :priority, 0), :desc)
  end

  defp skill_matches?(skill, normalized_message) do
    skill
    |> Map.get(:triggers, [])
    |> Enum.any?(&trigger_matches?(&1, normalized_message, skill))
  end

  defp trigger_matches?(trigger, _normalized_message, _skill) when not is_binary(trigger), do: false

  defp trigger_matches?(trigger, normalized_message, skill) do
    case parse_regex_trigger(trigger) do
      {:regex, pattern, options} -> regex_matches?(pattern, options, normalized_message, trigger, skill)
      :plain -> String.contains?(normalized_message, String.downcase(trigger))
    end
  end

  defp regex_matches?(pattern, options, normalized_message, original_trigger, skill) do
    case :re.run(normalized_message, pattern, [:unicode | options]) do
      {:match, _} -> true
      :nomatch -> false
      {:error, reason} ->
        log_invalid_regex(skill, original_trigger, reason)
        false
    end
  rescue
    error in ArgumentError ->
      log_invalid_regex(skill, original_trigger, Exception.message(error))
      false
  end

  defp parse_regex_trigger(trigger) do
    if String.starts_with?(trigger, "/") do
      split_regex_trigger(trigger)
    else
      :plain
    end
  end

  defp split_regex_trigger("/" <> rest) do
    with {index, 1} <- List.last(:binary.matches(rest, "/")),
         pattern when pattern != "" <- binary_part(rest, 0, index),
         flags <- binary_part(rest, index + 1, byte_size(rest) - index - 1) do
      {:regex, pattern, regex_options(flags)}
    else
      _ -> :plain
    end
  end

  defp regex_options(flags) do
    flags
    |> String.graphemes()
    |> Enum.map(&flag_option/1)
    |> Enum.reject(&is_nil/1)
  end

  defp flag_option("i"), do: :caseless
  defp flag_option("m"), do: :multiline
  defp flag_option("s"), do: :dotall
  defp flag_option("u"), do: :unicode
  defp flag_option("x"), do: :extended
  defp flag_option(_unknown_flag), do: nil

  defp log_invalid_regex(skill, trigger, reason) do
    Logger.warning(
      "Skipping invalid skill trigger regex for #{Map.get(skill, :name, "unknown")}: #{inspect(trigger)}: #{inspect(reason)}"
    )
  end
end
