defmodule ElixirClaw.Skills.MatcherTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ElixirClaw.Skills.Composer
  alias ElixirClaw.Skills.Matcher
  alias ElixirClaw.Skills.Skill

  describe "match_skills/2" do
    test "matches plain string triggers case-insensitively" do
      skills = [
        skill(name: "elixir-expert", triggers: ["elixir"]),
        skill(name: "rust-expert", triggers: ["rust"])
      ]

      assert [%{name: "elixir-expert"}] = Matcher.match_skills("Need ELIXIR help", skills)
    end

    test "matches regex triggers" do
      skills = [skill(name: "otp", triggers: ["/genserver|supervisor/"])]

      assert [%{name: "otp"}] = Matcher.match_skills("How should I use a supervisor?", skills)
    end

    test "returns no skills when nothing matches" do
      skills = [skill(name: "phoenix", triggers: ["phoenix"])]

      assert [] = Matcher.match_skills("Need help with protobuf", skills)
    end

    test "sorts matched skills by priority descending" do
      skills = [
        skill(name: "medium", triggers: ["elixir"], priority: 5),
        skill(name: "high", triggers: ["elixir"], priority: 10),
        skill(name: "low", triggers: ["elixir"], priority: 1)
      ]

      assert ["high", "medium", "low"] ==
               Matcher.match_skills("elixir", skills)
               |> Enum.map(& &1.name)
    end

    test "skips invalid regex triggers and logs a warning" do
      skills = [
        skill(name: "broken", triggers: ["/[unterminated/"]),
        skill(name: "valid", triggers: ["elixir"])
      ]

      log =
        capture_log(fn ->
          assert [%{name: "valid"}] = Matcher.match_skills("elixir", skills)
        end)

      assert log =~ "Skipping invalid skill trigger regex"
      assert log =~ "broken"
    end
  end

  describe "compose/2" do
    test "joins included skill contents and reports included metadata" do
      skills = [
        skill(name: "high", priority: 10, token_estimate: 20, content: "High content"),
        skill(name: "low", priority: 1, token_estimate: 10, content: "Low content")
      ]

      assert {"High content\n\n---\n\nLow content",
              %{skills_included: ["high", "low"], skills_excluded: [], total_tokens: 30}} =
               Composer.compose(skills, 30)
    end

    test "skips skills that exceed the remaining budget and keeps filling greedily" do
      skills = [
        skill(name: "first", priority: 10, token_estimate: 40, content: "First"),
        skill(name: "too-large", priority: 9, token_estimate: 70, content: "Too large"),
        skill(name: "fits", priority: 8, token_estimate: 20, content: "Fits")
      ]

      assert {"First\n\n---\n\nFits",
              %{
                skills_included: ["first", "fits"],
                skills_excluded: ["too-large"],
                total_tokens: 60
              }} =
               Composer.compose(skills, 60)
    end

    test "includes dependencies even when they were not directly matched" do
      dependency =
        skill(
          name: "clean-code",
          priority: 1,
          token_estimate: 10,
          content: "Clean code",
          direct_match?: false
        )

      matched = [
        skill(
          name: "elixir-expert",
          priority: 10,
          token_estimate: 20,
          content: "Elixir expert",
          depends_on: ["clean-code"]
        ),
        dependency
      ]

      assert {"Clean code\n\n---\n\nElixir expert",
              %{
                skills_included: ["clean-code", "elixir-expert"],
                skills_excluded: [],
                total_tokens: 30
              }} =
               Composer.compose(matched, 30)
    end

    test "excludes a skill when its required dependency would exceed budget" do
      matched = [
        skill(
          name: "elixir-expert",
          priority: 10,
          token_estimate: 25,
          content: "Elixir expert",
          depends_on: ["clean-code"]
        ),
        skill(
          name: "clean-code",
          priority: 1,
          token_estimate: 20,
          content: "Clean code",
          direct_match?: false
        ),
        skill(name: "small", priority: 0, token_estimate: 10, content: "Small")
      ]

      assert {"Small",
              %{
                skills_included: ["small"],
                skills_excluded: ["elixir-expert", "clean-code"],
                total_tokens: 10
              }} =
               Composer.compose(matched, 30)
    end
  end

  defp skill(attrs) do
    base = %{
      __struct__: Skill,
      name: "skill",
      description: nil,
      triggers: [],
      priority: 0,
      max_tokens: 1024,
      content: "content",
      token_estimate: 10,
      file_path: "test/fixtures/skills/generated.md",
      direct_match?: true
    }

    Map.merge(base, Enum.into(attrs, %{}))
  end
end
