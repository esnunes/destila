defmodule Destila.Workflows.SkillsTest do
  use ExUnit.Case, async: true

  alias Destila.Workflows.Skills

  describe "all_skills/0" do
    test "discovers skill files from priv/skills/" do
      skills = Skills.all_skills()
      identifiers = Enum.map(skills, & &1.identifier)
      assert "code_quality" in identifiers
    end

    test "parses name from frontmatter" do
      skill = Skills.all_skills() |> Enum.find(&(&1.identifier == "code_quality"))
      assert skill.name == "Code Quality"
    end

    test "parses always field from frontmatter" do
      skill = Skills.all_skills() |> Enum.find(&(&1.identifier == "code_quality"))
      assert skill.always == false
    end

    test "parses body content after frontmatter" do
      skill = Skills.all_skills() |> Enum.find(&(&1.identifier == "code_quality"))
      assert skill.body =~ "Code Quality"
      assert skill.body =~ "simple, direct, and minimal"
    end
  end

  describe "always_included/0" do
    test "returns only skills with always: true" do
      skills = Skills.always_included()
      assert Enum.all?(skills, & &1.always)
    end
  end

  describe "by_identifiers/1" do
    test "returns skills matching given identifiers" do
      skills = Skills.by_identifiers(["code_quality"])
      assert length(skills) == 1
      assert hd(skills).identifier == "code_quality"
    end

    test "returns empty list for unknown identifiers" do
      assert Skills.by_identifiers(["nonexistent"]) == []
    end
  end

  describe "assemble_prompt/2" do
    test "prepends skill sections before phase prompt" do
      result = Skills.assemble_prompt(["code_quality"], "Do the task.")
      assert result =~ "## Skill: Code Quality"
      assert result |> String.split("Do the task.") |> length() == 2
    end

    test "returns phase prompt unchanged when no skills apply" do
      result = Skills.assemble_prompt([], "Do the task.")
      assert String.ends_with?(result, "Do the task.")
    end

    test "deduplicates skills by identifier" do
      result = Skills.assemble_prompt(["code_quality", "code_quality"], "Do the task.")

      occurrences =
        result
        |> String.split("## Skill: Code Quality")
        |> length()

      # Should appear exactly once (2 parts = 1 occurrence)
      assert occurrences == 2
    end

    test "renders each skill with correct heading format" do
      result = Skills.assemble_prompt(["code_quality"], "Task.")
      assert result =~ "## Skill: Code Quality\n\n"
    end
  end
end
