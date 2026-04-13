defmodule Destila.AI.ToolsTest do
  use ExUnit.Case, async: true

  alias Destila.AI.Tools

  describe "tool_descriptions/1" do
    test "returns description for mcp__destila__session" do
      result = Tools.tool_descriptions(["mcp__destila__session"])
      assert result =~ "Phase Transitions"
      assert result =~ "suggest_phase_complete"
      assert result =~ "Exporting Data"
    end

    test "returns description for mcp__destila__ask_user_question" do
      result = Tools.tool_descriptions(["mcp__destila__ask_user_question"])
      assert result =~ "Asking Questions"
      assert result =~ "mcp__destila__ask_user_question"
    end

    test "returns descriptions for multiple tools" do
      result =
        Tools.tool_descriptions(["mcp__destila__ask_user_question", "mcp__destila__session"])

      assert result =~ "Asking Questions"
      assert result =~ "Phase Transitions"
      assert result =~ "Exporting Data"
    end

    test "ignores tools without descriptions" do
      result = Tools.tool_descriptions(["Read", "Write", "mcp__destila__session"])
      refute result =~ "Read"
      assert result =~ "Phase Transitions"
    end

    test "returns empty string when no tools have descriptions" do
      assert Tools.tool_descriptions(["Read", "Write", "Bash"]) == ""
    end
  end

  describe "described_tool_names/0" do
    test "returns destila tool names" do
      names = Tools.described_tool_names()
      assert "mcp__destila__session" in names
      assert "mcp__destila__ask_user_question" in names
    end
  end

  describe "non_interactive_context/0" do
    test "includes phase_complete instruction" do
      result = Tools.non_interactive_context()
      assert result =~ "phase_complete"
    end

    test "warns against suggest_phase_complete" do
      result = Tools.non_interactive_context()
      assert result =~ "Do NOT use `suggest_phase_complete`"
    end

    test "warns against ask_user_question" do
      result = Tools.non_interactive_context()
      assert result =~ "Do NOT call `mcp__destila__ask_user_question`"
    end
  end
end
