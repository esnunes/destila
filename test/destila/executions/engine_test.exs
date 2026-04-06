defmodule Destila.Executions.EngineTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.{AI, Executions, Workflows}
  alias Destila.Executions.Engine

  setup do
    ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
      text = "AI response"
      [ClaudeCode.Test.text(text), ClaudeCode.Test.result(text)]
    end)

    ClaudeCode.Test.set_mode_to_shared()

    :ok
  end

  defp create_session(attrs) do
    default = %{
      title: "Test Session",
      workflow_type: :brainstorm_idea,
      current_phase: 1,
      total_phases: 4,
      phase_status: :awaiting_input
    }

    {:ok, ws} = Workflows.insert_workflow_session(Map.merge(default, attrs))
    ws
  end

  defp create_session_with_ai(attrs) do
    ws = create_session(attrs)
    {:ok, _ai_session} = AI.create_ai_session(%{workflow_session_id: ws.id})
    ws
  end

  describe "phase_update/3 with suggest_phase_complete" do
    test "sets phase_status to advance_suggested" do
      ws = create_session_with_ai(%{})
      {:ok, pe} = Executions.create_phase_execution(ws, 1)
      Executions.start_phase(pe)

      # Simulate AI response that suggests phase complete
      ai_session = AI.get_ai_session_for_workflow(ws.id)

      AI.create_message(ai_session.id, %{
        role: :system,
        content: "Ready to advance",
        phase: 1
      })

      Engine.phase_update(ws.id, 1, %{
        ai_result: %{
          text: "Ready to advance",
          result: "Ready to advance",
          mcp_tool_uses: [
            %{
              name: "mcp__destila__session",
              input: %{action: "suggest_phase_complete", message: "Done"}
            }
          ]
        }
      })

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.phase_status == :advance_suggested

      updated_pe = Executions.get_phase_execution!(pe.id)
      assert updated_pe.status == :awaiting_confirmation
    end
  end

  describe "phase_update/3 with continue conversation" do
    test "sets phase_status to conversing" do
      ws = create_session_with_ai(%{phase_status: :processing})
      {:ok, pe} = Executions.create_phase_execution(ws, 1, %{status: :processing})

      Engine.phase_update(ws.id, 1, %{
        ai_result: %{text: "More questions", result: "More questions"}
      })

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.phase_status == :awaiting_input

      updated_pe = Executions.get_phase_execution!(pe.id)
      assert updated_pe.status == :awaiting_input
    end
  end

  describe "phase_update/3 with phase_complete on final phase" do
    test "marks workflow as done" do
      ws = create_session_with_ai(%{current_phase: 4, total_phases: 4})
      {:ok, _pe} = Executions.create_phase_execution(ws, 4)

      Engine.phase_update(ws.id, 4, %{
        ai_result: %{
          text: "Done",
          result: "Done",
          mcp_tool_uses: [
            %{
              name: "mcp__destila__session",
              input: %{action: "phase_complete", message: "All done"}
            }
          ]
        }
      })

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.done_at != nil
      assert is_nil(updated_ws.phase_status)
    end
  end

  describe "phase_update/3 with phase_complete on non-final phase" do
    test "auto-advances to next phase and creates phase execution" do
      ws = create_session_with_ai(%{current_phase: 1, total_phases: 4})
      {:ok, pe} = Executions.create_phase_execution(ws, 1)
      Executions.start_phase(pe)

      Engine.phase_update(ws.id, 1, %{
        ai_result: %{
          text: "Phase done",
          result: "Phase done",
          mcp_tool_uses: [
            %{
              name: "mcp__destila__session",
              input: %{action: "phase_complete", message: "Moving on"}
            }
          ]
        }
      })

      updated_ws = Workflows.get_workflow_session!(ws.id)
      # Should advance to phase 2 (Gherkin Review)
      assert updated_ws.current_phase == 2
      assert is_nil(updated_ws.done_at)

      # Current phase execution should be completed
      updated_pe = Executions.get_phase_execution!(pe.id)
      assert updated_pe.status == :completed

      # New phase execution should exist for phase 2
      new_pe = Executions.get_phase_execution_by_number(ws.id, 2)
      assert new_pe != nil
      assert new_pe.phase_name == "Gherkin Review"
    end
  end

  describe "phase_update/3 with user message" do
    test "enqueues worker and sets status to generating" do
      ws = create_session_with_ai(%{})

      Engine.phase_update(ws.id, 1, %{message: "Hello"})

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.phase_status == :processing
    end

    test "updates phase_execution status from awaiting_input to processing" do
      ws = create_session_with_ai(%{phase_status: :awaiting_input})
      {:ok, pe} = Executions.create_phase_execution(ws, 1, %{status: :awaiting_input})

      Engine.phase_update(ws.id, 1, %{message: "Hello"})

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.phase_status == :processing

      updated_pe = Executions.get_phase_execution!(pe.id)
      assert updated_pe.status == :processing
    end
  end

  describe "phase_update/3 with setup_step_completed" do
    test "transitions from setup to phase 1 when all setup steps complete" do
      ws = create_session_with_ai(%{phase_status: :setup})

      Workflows.upsert_metadata(ws.id, "creation", "title_gen", %{"status" => "completed"})
      Workflows.upsert_metadata(ws.id, "creation", "repo_sync", %{"status" => "completed"})
      Workflows.upsert_metadata(ws.id, "creation", "worktree", %{"status" => "completed"})

      Engine.phase_update(ws.id, 1, %{setup_step_completed: true})

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.current_phase == 1
      assert updated_ws.phase_status == :processing
      refute updated_ws.phase_status == :setup
    end

    test "stays in setup when not all steps complete" do
      ws = create_session(%{phase_status: :setup})

      Workflows.upsert_metadata(ws.id, "creation", "title_gen", %{"status" => "completed"})
      Workflows.upsert_metadata(ws.id, "creation", "repo_sync", %{"status" => "in_progress"})

      Engine.phase_update(ws.id, 1, %{setup_step_completed: true})

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.phase_status == :setup
    end

    test "creates phase execution for phase 1 after setup completes" do
      ws = create_session_with_ai(%{phase_status: :setup})

      Workflows.upsert_metadata(ws.id, "creation", "title_gen", %{"status" => "completed"})
      Workflows.upsert_metadata(ws.id, "creation", "repo_sync", %{"status" => "completed"})
      Workflows.upsert_metadata(ws.id, "creation", "worktree", %{"status" => "completed"})

      Engine.phase_update(ws.id, 1, %{setup_step_completed: true})

      pe = Executions.get_phase_execution_by_number(ws.id, 1)
      assert pe != nil
      assert pe.phase_name == "Task Description"
    end
  end

  describe "advance_to_next/1" do
    test "completes workflow when on last phase" do
      ws = create_session(%{current_phase: 4, total_phases: 4})

      Engine.advance_to_next(ws)

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.done_at != nil
    end

    test "advances to next phase" do
      ws = create_session_with_ai(%{current_phase: 1, total_phases: 4})

      Engine.advance_to_next(ws)

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.current_phase == 2

      # Phase execution should be created for the new phase
      pe = Executions.get_phase_execution_by_number(ws.id, 2)
      assert pe != nil
      assert pe.phase_name == "Gherkin Review"
    end

    test "completes current phase execution before advancing" do
      ws = create_session_with_ai(%{current_phase: 1, total_phases: 4})
      {:ok, pe} = Executions.create_phase_execution(ws, 1, %{status: :awaiting_confirmation})

      Engine.advance_to_next(ws)

      completed_pe = Executions.get_phase_execution!(pe.id)
      assert completed_pe.status == :completed
      assert completed_pe.completed_at != nil
    end

    test "accepts workflow session id string" do
      ws = create_session_with_ai(%{current_phase: 1, total_phases: 4})

      Engine.advance_to_next(ws.id)

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.current_phase == 2
    end

    test "completes awaiting_input phase execution before advancing" do
      ws = create_session_with_ai(%{current_phase: 1, total_phases: 4})
      {:ok, pe} = Executions.create_phase_execution(ws, 1, %{status: :awaiting_input})

      Engine.advance_to_next(ws)

      completed_pe = Executions.get_phase_execution!(pe.id)
      assert completed_pe.status == :completed
      assert completed_pe.completed_at != nil
    end

    test "completes failed phase execution before advancing" do
      ws = create_session_with_ai(%{current_phase: 1, total_phases: 4})
      {:ok, pe} = Executions.create_phase_execution(ws, 1, %{status: :failed})

      Engine.advance_to_next(ws)

      completed_pe = Executions.get_phase_execution!(pe.id)
      assert completed_pe.status == :completed
      assert completed_pe.completed_at != nil
    end
  end

  describe "phase_retry/1" do
    test "retries from awaiting_confirmation state" do
      ws = create_session_with_ai(%{phase_status: :advance_suggested})
      {:ok, pe} = Executions.create_phase_execution(ws, 1, %{status: :awaiting_confirmation})

      Engine.phase_retry(ws)

      updated_pe = Executions.get_phase_execution!(pe.id)
      assert updated_pe.status == :processing

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.phase_status == :processing
    end

    test "retries from awaiting_input state" do
      ws = create_session_with_ai(%{phase_status: :awaiting_input})
      {:ok, pe} = Executions.create_phase_execution(ws, 1, %{status: :awaiting_input})

      Engine.phase_retry(ws)

      updated_pe = Executions.get_phase_execution!(pe.id)
      assert updated_pe.status == :processing

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.phase_status == :processing
    end

    test "returns noop when already processing" do
      ws = create_session_with_ai(%{phase_status: :processing})

      assert Engine.phase_retry(ws) == :noop
    end
  end
end
