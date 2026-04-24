defmodule Destila.WorkflowTest do
  use ExUnit.Case, async: true

  alias Destila.Workflows
  alias Destila.Workflows.AISessionGroup
  alias Destila.Workflows.BrainstormIdeaWorkflow
  alias Destila.Workflows.CodeChatWorkflow
  alias Destila.Workflows.CodeRedesignAnalysisWorkflow
  alias Destila.Workflows.ImplementGeneralPromptWorkflow
  alias Destila.Workflows.Phase

  describe "Destila.Workflows.Workflow behaviour via BrainstormIdeaWorkflow" do
    test "total_phases/0 returns the correct count" do
      assert BrainstormIdeaWorkflow.total_phases() == 4
    end

    test "phase_name/1 returns the correct name for valid phases" do
      assert BrainstormIdeaWorkflow.phase_name(1) == "Task Description"
      assert BrainstormIdeaWorkflow.phase_name(2) == "Gherkin Review"
      assert BrainstormIdeaWorkflow.phase_name(4) == "Prompt Generation"
    end

    test "phase_name/1 returns nil for out-of-range or non-integer phases" do
      assert is_nil(BrainstormIdeaWorkflow.phase_name(5))
      assert is_nil(BrainstormIdeaWorkflow.phase_name("invalid"))
    end

    test "phase_columns/0 includes all phases and done" do
      columns = BrainstormIdeaWorkflow.phase_columns()
      assert length(columns) == 5
      assert List.last(columns) == {:done, "Done"}
      assert hd(columns) == {1, "Task Description"}
    end

    test "creation_label/0 returns expected label" do
      assert BrainstormIdeaWorkflow.creation_label() == "Idea"
    end

    test "source_metadata_key/0 returns nil" do
      assert BrainstormIdeaWorkflow.source_metadata_key() == nil
    end
  end

  describe "groups/0 shape" do
    test "BrainstormIdeaWorkflow exposes one empty-skills, empty-tools group" do
      [group] = BrainstormIdeaWorkflow.groups()

      assert %AISessionGroup{name: "Brainstorm", skills: [], allowed_tools: []} = group

      assert Enum.map(group.phases, & &1.name) == [
               "Task Description",
               "Gherkin Review",
               "Technical Concerns",
               "Prompt Generation"
             ]
    end

    test "CodeChatWorkflow exposes one group with code_quality skill and chat tools" do
      [group] = CodeChatWorkflow.groups()

      assert group.name == "Chat"
      assert group.skills == ["code_quality"]
      assert "Read" in group.allowed_tools
      assert "mcp__destila__ask_user_question" in group.allowed_tools
      assert length(group.allowed_tools) == 11

      [phase] = group.phases
      assert phase.name == "Chat"
      assert phase.skills == []
      refute Map.has_key?(phase, :allowed_tools)
    end

    test "ImplementGeneralPromptWorkflow splits into Planning and Implementation groups" do
      [planning, implementation] = ImplementGeneralPromptWorkflow.groups()

      assert planning.name == "Planning"
      assert planning.skills == ["code_quality"]
      assert "Read" in planning.allowed_tools
      assert Enum.map(planning.phases, & &1.name) == ["Generate Plan", "Deepen Plan"]

      assert implementation.name == "Implementation"
      assert implementation.skills == ["code_quality"]
      assert implementation.allowed_tools == planning.allowed_tools

      assert Enum.map(implementation.phases, & &1.name) == [
               "Work",
               "Review",
               "Browser Tests",
               "Feature Video",
               "Adjustments"
             ]
    end

    test "non_interactive flags match expectations" do
      brainstorm_phases = BrainstormIdeaWorkflow.phases()
      refute Enum.any?(brainstorm_phases, & &1.non_interactive)

      [chat] = CodeChatWorkflow.phases()
      refute chat.non_interactive

      implement_phases = ImplementGeneralPromptWorkflow.phases()

      assert Enum.map(implement_phases, &{&1.name, &1.non_interactive}) == [
               {"Generate Plan", true},
               {"Deepen Plan", true},
               {"Work", true},
               {"Review", true},
               {"Browser Tests", true},
               {"Feature Video", true},
               {"Adjustments", false}
             ]

      redesign_phases = CodeRedesignAnalysisWorkflow.phases()

      assert Enum.map(redesign_phases, &{&1.name, &1.non_interactive}) == [
               {"Extract Requirements", true},
               {"Greenfield Design", true},
               {"Compare & Improve", true},
               {"Adjustments", false}
             ]
    end

    test "CodeRedesignAnalysisWorkflow splits into Analysis, Design & Compare, and Adjustments groups" do
      [analysis, design_compare, adjustments] = CodeRedesignAnalysisWorkflow.groups()

      assert analysis.name == "Analysis"
      assert analysis.skills == ["code_quality"]
      assert "Read" in analysis.allowed_tools
      assert "mcp__destila__session" in analysis.allowed_tools
      refute "mcp__destila__ask_user_question" in analysis.allowed_tools
      assert length(analysis.allowed_tools) == 10
      assert Enum.map(analysis.phases, & &1.name) == ["Extract Requirements"]

      assert design_compare.name == "Design & Compare"
      assert design_compare.skills == ["code_quality"]
      assert design_compare.allowed_tools == analysis.allowed_tools

      assert Enum.map(design_compare.phases, & &1.name) == [
               "Greenfield Design",
               "Compare & Improve"
             ]

      assert adjustments.name == "Adjustments"
      assert adjustments.skills == ["code_quality"]
      assert adjustments.allowed_tools == analysis.allowed_tools
      assert Enum.map(adjustments.phases, & &1.name) == ["Adjustments"]
    end

    test "Phase struct has no legacy fields" do
      %Phase{} = phase = BrainstormIdeaWorkflow.phases() |> hd()
      refute Map.has_key?(phase, :session_strategy)
      refute Map.has_key?(phase, :allowed_tools)
      refute Map.has_key?(phase, :system_prompt)
    end
  end

  describe "phases/0 is derived from groups/0 by flattening" do
    test "BrainstormIdeaWorkflow phases match the flattened groups" do
      expected = Enum.flat_map(BrainstormIdeaWorkflow.groups(), & &1.phases)
      assert BrainstormIdeaWorkflow.phases() == expected
    end

    test "CodeChatWorkflow phases match the flattened groups" do
      expected = Enum.flat_map(CodeChatWorkflow.groups(), & &1.phases)
      assert CodeChatWorkflow.phases() == expected
    end

    test "ImplementGeneralPromptWorkflow phases match the flattened groups in order" do
      expected = Enum.flat_map(ImplementGeneralPromptWorkflow.groups(), & &1.phases)
      assert ImplementGeneralPromptWorkflow.phases() == expected

      assert Enum.map(expected, & &1.name) == [
               "Generate Plan",
               "Deepen Plan",
               "Work",
               "Review",
               "Browser Tests",
               "Feature Video",
               "Adjustments"
             ]
    end
  end

  describe "ImplementGeneralPromptWorkflow basics" do
    test "total_phases/0 returns 7" do
      assert ImplementGeneralPromptWorkflow.total_phases() == 7
    end

    test "phase_name/1 still resolves names via the flattened list" do
      assert ImplementGeneralPromptWorkflow.phase_name(3) == "Work"
    end

    test "phase_columns/0 ends with :done" do
      assert List.last(ImplementGeneralPromptWorkflow.phase_columns()) == {:done, "Done"}
      assert length(ImplementGeneralPromptWorkflow.phase_columns()) == 8
    end

    test "creation_label/0 returns expected label" do
      assert ImplementGeneralPromptWorkflow.creation_label() == "Prompt"
    end

    test "source_metadata_key/0 returns expected key" do
      assert ImplementGeneralPromptWorkflow.source_metadata_key() == "prompt_generated"
    end
  end

  describe "CodeRedesignAnalysisWorkflow basics" do
    test "total_phases/0 returns 4" do
      assert CodeRedesignAnalysisWorkflow.total_phases() == 4
    end

    test "phase_name/1 maps to the expected phase names" do
      assert CodeRedesignAnalysisWorkflow.phase_name(1) == "Extract Requirements"
      assert CodeRedesignAnalysisWorkflow.phase_name(2) == "Greenfield Design"
      assert CodeRedesignAnalysisWorkflow.phase_name(3) == "Compare & Improve"
      assert CodeRedesignAnalysisWorkflow.phase_name(4) == "Adjustments"
      assert is_nil(CodeRedesignAnalysisWorkflow.phase_name(5))
    end

    test "phase_columns/0 ends with :done and has length 5" do
      columns = CodeRedesignAnalysisWorkflow.phase_columns()
      assert length(columns) == 5
      assert List.last(columns) == {:done, "Done"}
      assert hd(columns) == {1, "Extract Requirements"}
    end

    test "creation_label/0 returns Scope" do
      assert CodeRedesignAnalysisWorkflow.creation_label() == "Scope"
    end

    test "source_metadata_key/0 returns nil" do
      assert CodeRedesignAnalysisWorkflow.source_metadata_key() == nil
    end

    test "label, description, default_title, completion_message, icon, icon_class are non-empty strings" do
      for fun <- [:label, :description, :default_title, :completion_message, :icon, :icon_class] do
        value = apply(CodeRedesignAnalysisWorkflow, fun, [])
        assert is_binary(value)
        assert value != ""
      end
    end

    test "Workflows.groups dispatcher matches the module's groups" do
      assert Workflows.groups(:code_redesign_analysis) == CodeRedesignAnalysisWorkflow.groups()
    end
  end

  describe "Workflows.group_for_phase/2" do
    test "returns Planning for phases 1-2 of implement_general_prompt" do
      [planning, _] = ImplementGeneralPromptWorkflow.groups()
      assert Workflows.group_for_phase(:implement_general_prompt, 1) == planning
      assert Workflows.group_for_phase(:implement_general_prompt, 2) == planning
    end

    test "returns Implementation for phases 3-7 of implement_general_prompt" do
      [_, implementation] = ImplementGeneralPromptWorkflow.groups()
      assert Workflows.group_for_phase(:implement_general_prompt, 3) == implementation
      assert Workflows.group_for_phase(:implement_general_prompt, 7) == implementation
    end

    test "returns nil for out-of-range phase numbers" do
      assert Workflows.group_for_phase(:implement_general_prompt, 0) == nil
      assert Workflows.group_for_phase(:implement_general_prompt, 8) == nil
      assert Workflows.group_for_phase(:implement_general_prompt, -1) == nil
    end

    test "returns the single group for single-group workflows" do
      [brainstorm] = BrainstormIdeaWorkflow.groups()
      assert Workflows.group_for_phase(:brainstorm_idea, 1) == brainstorm
      assert Workflows.group_for_phase(:brainstorm_idea, 4) == brainstorm
      assert Workflows.group_for_phase(:brainstorm_idea, 5) == nil
    end

    test "returns the right group for each phase of code_redesign_analysis" do
      [analysis, design_compare, adjustments] = CodeRedesignAnalysisWorkflow.groups()

      assert Workflows.group_for_phase(:code_redesign_analysis, 1) == analysis
      assert Workflows.group_for_phase(:code_redesign_analysis, 2) == design_compare
      assert Workflows.group_for_phase(:code_redesign_analysis, 3) == design_compare
      assert Workflows.group_for_phase(:code_redesign_analysis, 4) == adjustments
      assert Workflows.group_for_phase(:code_redesign_analysis, 5) == nil
      assert Workflows.group_for_phase(:code_redesign_analysis, 0) == nil
    end
  end

  describe "Workflows.groups/1 dispatcher" do
    test "returns the workflow module's groups" do
      assert Workflows.groups(:implement_general_prompt) ==
               ImplementGeneralPromptWorkflow.groups()
    end
  end
end
