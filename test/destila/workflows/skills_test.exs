defmodule Destila.Workflows.SkillsTest do
  use ExUnit.Case, async: true

  alias Destila.Workflows.Skills

  describe "all_skills/0" do
    test "discovers skill files from priv/skills/" do
      skills = Skills.all_skills()
      identifiers = Enum.map(skills, & &1.identifier)
      assert "interactive_tool_instructions" in identifiers
      assert "non_interactive_tool_instructions" in identifiers
    end

    test "parses name from frontmatter" do
      skill =
        Skills.all_skills() |> Enum.find(&(&1.identifier == "interactive_tool_instructions"))

      assert skill.name == "Interactive Tool Instructions"
    end

    test "parses always field from frontmatter" do
      skill =
        Skills.all_skills() |> Enum.find(&(&1.identifier == "interactive_tool_instructions"))

      assert skill.always == false
    end

    test "parses body content after frontmatter" do
      skill =
        Skills.all_skills() |> Enum.find(&(&1.identifier == "interactive_tool_instructions"))

      assert skill.body =~ "Asking Questions"
      assert skill.body =~ "mcp__destila__ask_user_question"
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
      skills = Skills.by_identifiers(["interactive_tool_instructions"])
      assert length(skills) == 1
      assert hd(skills).identifier == "interactive_tool_instructions"
    end

    test "returns empty list for unknown identifiers" do
      assert Skills.by_identifiers(["nonexistent"]) == []
    end
  end

  describe "assemble_prompt/2" do
    test "prepends skill sections before phase prompt" do
      result = Skills.assemble_prompt(["interactive_tool_instructions"], "Do the task.")
      assert result =~ "## Skill: Interactive Tool Instructions"
      assert result |> String.split("Do the task.") |> length() == 2
    end

    test "returns phase prompt unchanged when no skills apply" do
      result = Skills.assemble_prompt([], "Do the task.")
      assert String.ends_with?(result, "Do the task.")
    end

    test "deduplicates skills by identifier" do
      result =
        Skills.assemble_prompt(
          ["interactive_tool_instructions", "interactive_tool_instructions"],
          "Do the task."
        )

      occurrences =
        result
        |> String.split("## Skill: Interactive Tool Instructions")
        |> length()

      # Should appear exactly once (2 parts = 1 occurrence)
      assert occurrences == 2
    end

    test "renders each skill with correct heading format" do
      result = Skills.assemble_prompt(["non_interactive_tool_instructions"], "Task.")
      assert result =~ "## Skill: Non-Interactive Tool Instructions\n\n"
    end
  end
end
