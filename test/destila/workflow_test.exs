defmodule Destila.WorkflowTest do
  use ExUnit.Case, async: true

  alias Destila.Workflows.BrainstormIdeaWorkflow
  alias Destila.Workflows.ImplementGeneralPromptWorkflow

  describe "Destila.Workflow behaviour via BrainstormIdeaWorkflow" do
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

    test "session_strategy defaults to :resume for all phases" do
      for phase <- BrainstormIdeaWorkflow.phases() do
        assert phase.session_strategy == :resume
      end
    end

    test "creation_config/0 returns expected tuple" do
      assert BrainstormIdeaWorkflow.creation_config() == {nil, "Idea", "idea"}
    end
  end

  describe "ImplementGeneralPromptWorkflow session_strategy in Phase struct" do
    test "Work phase (3rd) has session_strategy :new" do
      work_phase = Enum.at(ImplementGeneralPromptWorkflow.phases(), 2)
      assert work_phase.session_strategy == :new
    end

    test "all other phases default to :resume" do
      phases = ImplementGeneralPromptWorkflow.phases()

      for {phase, idx} <- Enum.with_index(phases), idx != 2 do
        assert phase.session_strategy == :resume,
               "Expected :resume for phase #{idx + 1} (#{phase.name}), got #{inspect(phase.session_strategy)}"
      end
    end

    test "total_phases/0 returns 7" do
      assert ImplementGeneralPromptWorkflow.total_phases() == 7
    end

    test "creation_config/0 returns expected tuple" do
      assert ImplementGeneralPromptWorkflow.creation_config() ==
               {"prompt_generated", "Prompt", "prompt"}
    end
  end
end
