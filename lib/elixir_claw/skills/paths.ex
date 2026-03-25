defmodule ElixirClaw.Skills.Paths do
  @moduledoc false

  @user_skills_segments [".agents", "skills"]

  @spec default_paths() :: [String.t()]
  def default_paths do
    [Path.join([System.user_home!() | @user_skills_segments])]
  end

  @spec resolve(term()) :: [String.t()]
  def resolve(paths) do
    paths
    |> List.wrap()
    |> List.flatten()
    |> Enum.concat(default_paths())
    |> Enum.filter(&valid_path?/1)
    |> Enum.map(&expand_path/1)
    |> Enum.uniq()
  end

  defp valid_path?(path) when is_binary(path), do: String.trim(path) != ""
  defp valid_path?(_path), do: false

  defp expand_path("~" <> rest), do: Path.expand(Path.join(System.user_home!(), rest))
  defp expand_path(path), do: Path.expand(path)
end
