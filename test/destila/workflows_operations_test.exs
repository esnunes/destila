defmodule Destila.WorkflowsOperationsTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.Workflows

  defp create_session(attrs \\ %{}) do
    defaults = %{
      title: "Test Session",
      workflow_type: :prompt_chore_task,
      current_phase: 2,
      total_phases: 6
    }

    {:ok, ws} = Workflows.create_workflow_session(Map.merge(defaults, attrs))
    ws
  end

  describe "create_session_from_wizard/3" do
    test "creates a session with next phase and default title" do
      {:ok, ws} =
        Workflows.create_session_from_wizard(:prompt_chore_task, 1, %{
          project_id: nil,
          idea: "Fix the login bug",
          title_generating: true
        })

      assert ws.workflow_type == :prompt_chore_task
      assert ws.current_phase == 2
      assert ws.total_phases == 6
      assert ws.title == "New Chore/Task"
      assert ws.title_generating == true
    end

    test "stores the idea as wizard metadata" do
      {:ok, ws} =
        Workflows.create_session_from_wizard(:prompt_chore_task, 1, %{
          idea: "Add dark mode"
        })

      metadata = Workflows.get_metadata(ws.id)
      assert metadata["idea"] == %{"text" => "Add dark mode"}
    end

    test "skips metadata when idea is nil" do
      {:ok, ws} =
        Workflows.create_session_from_wizard(:prompt_chore_task, 1, %{
          idea: nil
        })

      metadata = Workflows.get_metadata(ws.id)
      assert metadata == %{}
    end

    test "sets project_id when provided" do
      {:ok, project} =
        Destila.Projects.create_project(%{name: "Test Project", local_folder: "/tmp/test"})

      {:ok, ws} =
        Workflows.create_session_from_wizard(:prompt_chore_task, 1, %{
          project_id: project.id,
          idea: "Some idea"
        })

      assert ws.project_id == project.id
    end
  end

  describe "advance_phase/2" do
    test "advances to the next phase with nil phase_status by default" do
      ws = create_session(%{current_phase: 3, total_phases: 6})
      {:ok, updated} = Workflows.advance_phase(ws)

      assert updated.current_phase == 4
      assert updated.phase_status == nil
    end

    test "accepts a custom phase_status" do
      ws = create_session(%{current_phase: 3, total_phases: 6})
      {:ok, updated} = Workflows.advance_phase(ws, phase_status: :generating)

      assert updated.current_phase == 4
      assert updated.phase_status == :generating
    end

    test "returns error at boundary when already at last phase" do
      ws = create_session(%{current_phase: 6, total_phases: 6})
      assert {:error, :at_boundary} = Workflows.advance_phase(ws)
    end
  end

  describe "mark_done/1" do
    test "sets done_at and clears phase_status" do
      ws = create_session(%{phase_status: :conversing})
      {:ok, updated} = Workflows.mark_done(ws)

      assert updated.done_at != nil
      assert updated.phase_status == nil
    end

    test "creates a completion message when AI session exists" do
      ws = create_session()
      {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

      {:ok, _updated} = Workflows.mark_done(ws)

      messages = Destila.AI.list_messages(ai_session.id)
      assert length(messages) == 1
      completion = hd(messages)
      assert completion.role == :system
      assert completion.content =~ "implementation prompt is ready"
    end

    test "succeeds when no AI session exists" do
      ws = create_session()
      {:ok, updated} = Workflows.mark_done(ws)

      assert updated.done_at != nil
    end
  end
end
