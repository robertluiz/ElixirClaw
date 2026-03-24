defmodule ElixirClaw.Skills.Skill do
  @moduledoc """
  Represents a parsed SKILL.md file.
  """

  @enforce_keys [:name, :content, :token_estimate, :file_path]
  defstruct [
    :name,
    :description,
    :content,
    :token_estimate,
    :file_path,
    triggers: [],
    priority: 0,
    max_tokens: 1024
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          triggers: [String.t()],
          priority: integer(),
          max_tokens: integer(),
          content: String.t(),
          token_estimate: non_neg_integer(),
          file_path: String.t()
        }
end

defmodule ElixirClaw.Skills.Loader do
  @moduledoc """
  Loads SKILL.md files with simple frontmatter parsing.
  """

  alias ElixirClaw.Skills.Skill

  @type load_result :: {:ok, Skill.t()} | {:error, atom()}
  @type dir_load_result :: {:ok, Skill.t()} | {:error, {String.t(), atom()}}

  @spec load_skill(Path.t()) :: load_result()
  def load_skill(path) do
    case File.read(path) do
      {:ok, contents} ->
        with {:ok, frontmatter_lines, body_lines} <- split_frontmatter(contents),
             {:ok, attributes} <- parse_frontmatter(frontmatter_lines),
             {:ok, skill} <- build_skill(attributes, body_lines, path) do
          {:ok, skill}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec load_skills_dir(Path.t()) :: [dir_load_result()]
  def load_skills_dir(dir_path) do
    dir_path
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      case load_skill(path) do
        {:ok, %Skill{} = skill} -> {:ok, skill}
        {:error, reason} -> {:error, {path, reason}}
      end
    end)
  end

  defp split_frontmatter(contents) do
    lines = String.split(contents, ~r/\r\n|\n|\r/, trim: false)

    case lines do
      ["---" | rest] -> collect_frontmatter(rest, [])
      _ -> {:error, :invalid_frontmatter}
    end
  end

  defp collect_frontmatter([], _frontmatter_lines), do: {:error, :invalid_frontmatter}

  defp collect_frontmatter(["---" | body_lines], frontmatter_lines) do
    {:ok, Enum.reverse(frontmatter_lines), body_lines}
  end

  defp collect_frontmatter([line | rest], frontmatter_lines) do
    collect_frontmatter(rest, [line | frontmatter_lines])
  end

  defp parse_frontmatter(lines) do
    Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, acc} ->
      case parse_frontmatter_line(line) do
        :skip -> {:cont, {:ok, acc}}
        {:ok, key, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_frontmatter_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        :skip

      true ->
        case String.split(trimmed, ":", parts: 2) do
          [key, value] ->
            {:ok, String.trim(key), parse_value(String.trim(value))}

          _ ->
            {:error, :invalid_frontmatter}
        end
    end
  end

  defp parse_value("[" <> rest) do
    rest
    |> String.trim_trailing("]")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_value(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> value
    end
  end

  defp build_skill(%{"name" => name} = attributes, body_lines, path) when is_binary(name) do
    content = Enum.join(body_lines, "\n")

    {:ok,
     %Skill{
       name: name,
       description: Map.get(attributes, "description"),
       triggers: normalize_triggers(Map.get(attributes, "triggers", [])),
       priority: Map.get(attributes, "priority", 0),
       max_tokens: Map.get(attributes, "max_tokens", 1024),
       content: content,
       token_estimate: div(String.length(content), 4),
       file_path: path
     }}
  end

  defp build_skill(_attributes, _body_lines, _path), do: {:error, :missing_required_field}

  defp normalize_triggers(triggers) when is_list(triggers), do: Enum.map(triggers, &to_string/1)
  defp normalize_triggers(_), do: []
end
