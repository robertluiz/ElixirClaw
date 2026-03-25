defmodule ElixirClaw.Skills.LoaderTest do
  use ExUnit.Case, async: true

  alias ElixirClaw.Skills.Loader
  alias ElixirClaw.Skills.Skill

  @fixtures_dir Path.expand("../../fixtures/skills", __DIR__)

  describe "load_skill/1" do
    test "loads a valid SKILL.md with all frontmatter fields" do
      path = Path.join(@fixtures_dir, "valid_skill.md")

      assert {:ok, %Skill{} = skill} = Loader.load_skill(path)
      assert skill.name == "elixir-expert"
      assert skill.description == "Expert Elixir developer"
      assert skill.triggers == ["elixir", "otp", "genserver"]
      assert skill.priority == 10
      assert skill.max_tokens == 2048
      assert skill.file_path == path
      assert skill.content == "# Elixir Expert\n\nHandles OTP and Phoenix work.\n"
      assert skill.token_estimate == div(String.length(skill.content), 4)
    end

    test "loads a skill with defaults when optional frontmatter fields are missing" do
      path = Path.join(@fixtures_dir, "minimal_skill.md")

      assert {:ok, %Skill{} = skill} = Loader.load_skill(path)
      assert skill.name == "minimal-skill"
      assert skill.description == nil
      assert skill.triggers == []
      assert skill.priority == 0
      assert skill.max_tokens == 1024
      assert skill.content == "Minimal body content.\n"
      assert skill.token_estimate == div(String.length(skill.content), 4)
    end

    test "returns :missing_required_field when name is missing" do
      path = Path.join(@fixtures_dir, "missing_name.md")

      assert {:error, :missing_required_field} = Loader.load_skill(path)
    end

    test "returns :invalid_frontmatter when file has no frontmatter delimiters" do
      path = Path.join(@fixtures_dir, "no_frontmatter.md")

      assert {:error, :invalid_frontmatter} = Loader.load_skill(path)
    end

    test "returns :invalid_frontmatter when closing delimiter is missing" do
      path = Path.join(@fixtures_dir, "malformed_frontmatter.md")

      assert {:error, :invalid_frontmatter} = Loader.load_skill(path)
    end

    test "returns :enoent when file does not exist" do
      path = Path.join(@fixtures_dir, "missing.md")

      assert {:error, :enoent} = Loader.load_skill(path)
    end
  end

  describe "load_skills_dir/1" do
    test "loads every markdown file in a directory and preserves success or error tuples" do
      results = Loader.load_skills_dir(@fixtures_dir)

      assert length(results) == 5

      result_by_file =
        Map.new(results, fn
          {:ok, %Skill{file_path: file_path} = skill} -> {Path.basename(file_path), {:ok, skill}}
          {:error, {file_path, reason}} -> {Path.basename(file_path), {:error, reason}}
        end)

      assert {:ok, %Skill{name: "elixir-expert"}} = result_by_file["valid_skill.md"]
      assert {:ok, %Skill{name: "minimal-skill"}} = result_by_file["minimal_skill.md"]
      assert {:error, :missing_required_field} = result_by_file["missing_name.md"]
      assert {:error, :invalid_frontmatter} = result_by_file["no_frontmatter.md"]
      assert {:error, :invalid_frontmatter} = result_by_file["malformed_frontmatter.md"]
    end

    test "returns an empty list when the directory has no markdown files" do
      empty_dir =
        Path.join(@fixtures_dir, "empty_#{System.unique_integer([:positive])}")

      File.mkdir_p!(empty_dir)

      on_exit(fn -> File.rm_rf!(empty_dir) end)

      assert Loader.load_skills_dir(empty_dir) == []
    end
  end

  describe "load_skills_dirs/1" do
    test "loads skills from multiple directories after path resolution" do
      extra_dir = Path.join(System.tmp_dir!(), "skills_extra_#{System.unique_integer([:positive])}")
      File.mkdir_p!(extra_dir)

      extra_skill_path = Path.join(extra_dir, "extra_skill.md")

      File.write!(extra_skill_path, """
      ---
      name: extra-skill
      description: Extra skill
      ---

      Extra body.
      """)

      on_exit(fn -> File.rm_rf!(extra_dir) end)

      results = Loader.load_skills_dirs([@fixtures_dir, extra_dir])

      loaded_names =
        results
        |> Enum.flat_map(fn
          {:ok, %Skill{name: name}} -> [name]
          _ -> []
        end)

      assert "elixir-expert" in loaded_names
      assert "minimal-skill" in loaded_names
      assert "extra-skill" in loaded_names
    end
  end
end
