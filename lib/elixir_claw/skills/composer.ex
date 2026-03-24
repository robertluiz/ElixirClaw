defmodule ElixirClaw.Skills.Composer do
  @moduledoc """
  Greedily composes matched skills within a token budget.
  """

  alias ElixirClaw.Skills.Skill

  @separator "\n\n---\n\n"

  @spec compose([Skill.t() | map()], integer()) ::
          {String.t(), %{skills_included: [String.t()], skills_excluded: [String.t()], total_tokens: integer()}}
  def compose(matched_skills, token_budget) when is_list(matched_skills) and is_integer(token_budget) do
    sorted_skills = Enum.sort_by(matched_skills, &Map.get(&1, :priority, 0), :desc)
    skill_index = Map.new(sorted_skills, &{Map.fetch!(&1, :name), &1})

    result =
      sorted_skills
      |> Enum.filter(&Map.get(&1, :direct_match?, true))
      |> Enum.reduce(%{included: [], included_names: MapSet.new(), excluded: [], total_tokens: 0}, fn skill, acc ->
        maybe_include_skill(skill, acc, skill_index, token_budget)
      end)

    content =
      result.included
      |> Enum.map(&Map.fetch!(&1, :content))
      |> Enum.join(@separator)

    metadata = %{
      skills_included: Enum.map(result.included, &Map.fetch!(&1, :name)),
      skills_excluded: Enum.reverse(result.excluded),
      total_tokens: result.total_tokens
    }

    {content, metadata}
  end

  defp maybe_include_skill(skill, acc, skill_index, token_budget) do
    if MapSet.member?(acc.included_names, Map.fetch!(skill, :name)) do
      acc
    else
      case dependency_bundle(skill, skill_index, acc.included_names, MapSet.new()) do
        {:ok, bundle} ->
          bundle_tokens = Enum.reduce(bundle, 0, &(&1.token_estimate + &2))

          if acc.total_tokens + bundle_tokens <= token_budget do
            Enum.reduce(bundle, acc, fn bundle_skill, bundle_acc ->
              include_skill(bundle_acc, bundle_skill)
            end)
          else
            exclude_bundle(acc, bundle)
          end

        {:error, missing_names} ->
          exclude_names(acc, [Map.fetch!(skill, :name) | missing_names])
      end
    end
  end

  defp dependency_bundle(skill, skill_index, included_names, visiting) do
    name = Map.fetch!(skill, :name)

    cond do
      MapSet.member?(included_names, name) ->
        {:ok, []}

      MapSet.member?(visiting, name) ->
        {:ok, []}

      true ->
        visiting = MapSet.put(visiting, name)

        with {:ok, dependencies} <- resolve_dependencies(Map.get(skill, :depends_on, []), skill_index, included_names, visiting) do
          {:ok, dependencies ++ [skill]}
        end
    end
  end

  defp resolve_dependencies(dependency_names, skill_index, included_names, visiting) do
    Enum.reduce_while(dependency_names, {:ok, []}, fn dependency_name, {:ok, acc} ->
      case Map.fetch(skill_index, dependency_name) do
        {:ok, dependency_skill} ->
          case dependency_bundle(dependency_skill, skill_index, included_names, visiting) do
            {:ok, bundle} -> {:cont, {:ok, acc ++ bundle}}
            {:error, missing_names} -> {:halt, {:error, missing_names}}
          end

        :error ->
          {:halt, {:error, [dependency_name]}}
      end
    end)
    |> dedupe_bundle()
  end

  defp dedupe_bundle({:error, missing_names}), do: {:error, Enum.uniq(missing_names)}

  defp dedupe_bundle({:ok, bundle}) do
    {:ok,
     Enum.reduce(bundle, {[], MapSet.new()}, fn skill, {acc, seen} ->
       name = Map.fetch!(skill, :name)

       if MapSet.member?(seen, name) do
         {acc, seen}
       else
         {[skill | acc], MapSet.put(seen, name)}
       end
     end)
     |> elem(0)
     |> Enum.reverse()}
  end

  defp include_skill(acc, skill) do
    name = Map.fetch!(skill, :name)

    if MapSet.member?(acc.included_names, name) do
      acc
    else
      %{
        acc
        | included: acc.included ++ [skill],
          included_names: MapSet.put(acc.included_names, name),
          excluded: List.delete(acc.excluded, name),
          total_tokens: acc.total_tokens + Map.get(skill, :token_estimate, 0)
      }
    end
  end

  defp exclude_bundle(acc, bundle) do
    bundle
    |> Enum.map(&Map.fetch!(&1, :name))
    |> Enum.reverse()
    |> exclude_names(acc)
  end

  defp exclude_names(names, acc) when is_list(names) do
    Enum.reduce(names, acc, fn name, names_acc ->
      if MapSet.member?(names_acc.included_names, name) or name in names_acc.excluded do
        names_acc
      else
        %{names_acc | excluded: [name | names_acc.excluded]}
      end
    end)
  end

  defp exclude_names(acc, names), do: exclude_names(names, acc)
end
