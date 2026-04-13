defmodule Destila.AI.ToolsTest do
  use ExUnit.Case, async: true

  alias Destila.AI.Tools

  describe "prompt_instructions/1" do
    test ":interactive includes asking questions instructions" do
      result = Tools.prompt_instructions(:interactive)
      assert result =~ "Asking Questions"
      assert result =~ "mcp__destila__ask_user_question"
    end

    test ":interactive includes suggest_phase_complete" do
      result = Tools.prompt_instructions(:interactive)
      assert result =~ "suggest_phase_complete"
    end

    test ":interactive includes export instructions" do
      result = Tools.prompt_instructions(:interactive)
      assert result =~ "Exporting Data"
      assert result =~ ~s(action: "export")
    end

    test ":non_interactive includes phase_complete only" do
      result = Tools.prompt_instructions(:non_interactive)
      assert result =~ "phase_complete"
      assert result =~ "Do NOT use `suggest_phase_complete`"
    end

    test ":non_interactive excludes asking questions" do
      result = Tools.prompt_instructions(:non_interactive)
      refute result =~ "Asking Questions"
      assert result =~ "Do NOT call `mcp__destila__ask_user_question`"
    end

    test ":non_interactive includes export instructions" do
      result = Tools.prompt_instructions(:non_interactive)
      assert result =~ "Exporting Data"
      assert result =~ ~s(action: "export")
    end
  end
end
