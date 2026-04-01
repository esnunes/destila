defmodule Destila.WorkflowTest do
  use ExUnit.Case, async: true

  alias Destila.Workflows.BrainstormIdeaWorkflow
  alias Destila.Workflows.ImplementGeneralPromptWorkflow

  describe "Destila.Workflow behaviour via BrainstormIdeaWorkflow" do
    test "total_phases/0 returns the correct count" do
      assert BrainstormIdeaWorkflow.total_phases() == 6
    end

    test "phase_name/1 returns the correct name for valid phases" do
      assert BrainstormIdeaWorkflow.phase_name(1) == "Project & Idea"
      assert BrainstormIdeaWorkflow.phase_name(3) == "Task Description"
      assert BrainstormIdeaWorkflow.phase_name(6) == "Prompt Generation"
    end

    test "phase_name/1 returns nil for out-of-range or non-integer phases" do
      assert is_nil(BrainstormIdeaWorkflow.phase_name(7))
      assert is_nil(BrainstormIdeaWorkflow.phase_name("invalid"))
    end

    test "phase_columns/0 includes all phases and done" do
      columns = BrainstormIdeaWorkflow.phase_columns()
      assert length(columns) == 7
      assert List.last(columns) == {:done, "Done"}
      assert hd(columns) == {1, "Project & Idea"}
    end

    test "session_strategy/1 defaults to :resume" do
      assert BrainstormIdeaWorkflow.session_strategy(1) == :resume
      assert BrainstormIdeaWorkflow.session_strategy(3) == :resume
    end
  end

  describe "ImplementGeneralPromptWorkflow overrides session_strategy" do
    test "returns :new for phase 5" do
      assert ImplementGeneralPromptWorkflow.session_strategy(5) == :new
    end

    test "returns :resume for other phases" do
      assert ImplementGeneralPromptWorkflow.session_strategy(1) == :resume
      assert ImplementGeneralPromptWorkflow.session_strategy(4) == :resume
      assert ImplementGeneralPromptWorkflow.session_strategy(6) == :resume
    end

    test "total_phases/0 returns 9" do
      assert ImplementGeneralPromptWorkflow.total_phases() == 9
    end
  end
end
