defmodule Destila.Agent.WorkflowLoaderTest do
  use ExUnit.Case, async: false

  alias Destila.Agent.WorkflowLoader

  test "load_all/0 loads the bundled example workflow" do
    assert :ok = WorkflowLoader.load_all()
    {:ok, wf} = WorkflowLoader.get("example")

    assert wf.name == "example"
    assert length(wf.phases) >= 1
    [phase | _] = wf.phases
    assert phase.name != ""
    assert phase.system_prompt != ""
    assert phase.kickoff_prompt != ""
    assert is_list(phase.agent_command)
  end

  test "get/1 returns :not_found for unknown workflows" do
    WorkflowLoader.load_all()
    assert {:error, :not_found} = WorkflowLoader.get("definitely_not_a_workflow")
  end

  test "list_all/0 returns workflow defs" do
    WorkflowLoader.load_all()
    names = Enum.map(WorkflowLoader.list_all(), & &1.name)
    assert "example" in names
  end
end
