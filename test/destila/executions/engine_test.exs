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

  defp create_session(attrs \\ %{}) do
    default = %{
      title: "Test Session",
      workflow_type: :prompt_chore_task,
      current_phase: 3,
      total_phases: 6,
      phase_status: :conversing
    }

    {:ok, ws} = Workflows.create_workflow_session(Map.merge(default, attrs))
    ws
  end

  defp create_session_with_ai(attrs) do
    ws = create_session(attrs)
    {:ok, _ai_session} = AI.create_ai_session(%{workflow_session_id: ws.id})
    ws
  end

  describe "handle_phase_result/3 with suggest_phase_complete" do
    test "sets phase_status to advance_suggested" do
      ws = create_session()
      {:ok, pe} = Executions.create_phase_execution(ws, 3)
      Executions.start_phase(pe)

      Engine.handle_phase_result(ws.id, 3, %{action: "suggest_phase_complete"})

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.phase_status == :advance_suggested

      updated_pe = Executions.get_phase_execution!(pe.id)
      assert updated_pe.status == "awaiting_confirmation"
    end
  end

  describe "handle_phase_result/3 with nil action (continue conversation)" do
    test "sets phase_status to conversing" do
      ws = create_session(%{phase_status: :generating})
      {:ok, pe} = Executions.create_phase_execution(ws, 3, %{status: "processing"})

      Engine.handle_phase_result(ws.id, 3, nil)

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.phase_status == :conversing

      updated_pe = Executions.get_phase_execution!(pe.id)
      assert updated_pe.status == "awaiting_input"
    end
  end

  describe "handle_phase_result/3 with phase_complete on final phase" do
    test "marks workflow as done" do
      ws = create_session(%{current_phase: 6, total_phases: 6})
      {:ok, _pe} = Executions.create_phase_execution(ws, 6)

      Engine.handle_phase_result(ws.id, 6, %{action: "phase_complete"})

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.done_at != nil
      assert is_nil(updated_ws.phase_status)
    end
  end

  describe "handle_phase_result/3 with phase_complete on non-final phase" do
    test "auto-advances to next phase and creates phase execution" do
      ws = create_session_with_ai(%{current_phase: 3, total_phases: 6})
      {:ok, pe} = Executions.create_phase_execution(ws, 3)
      Executions.start_phase(pe)

      Engine.handle_phase_result(ws.id, 3, %{action: "phase_complete"})

      updated_ws = Workflows.get_workflow_session!(ws.id)
      # Should advance to phase 4 (Gherkin Review)
      assert updated_ws.current_phase == 4
      assert is_nil(updated_ws.done_at)

      # Current phase execution should be completed
      updated_pe = Executions.get_phase_execution!(pe.id)
      assert updated_pe.status == "completed"

      # New phase execution should exist for phase 4
      new_pe = Executions.get_phase_execution_by_number(ws.id, 4)
      assert new_pe != nil
      assert new_pe.phase_name == "Gherkin Review"
    end
  end

  describe "advance_to_next/1" do
    test "completes workflow when on last phase" do
      ws = create_session(%{current_phase: 6, total_phases: 6})

      Engine.advance_to_next(ws)

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.done_at != nil
    end

    test "advances to next phase" do
      ws = create_session_with_ai(%{current_phase: 2, total_phases: 6})

      Engine.advance_to_next(ws)

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.current_phase == 3

      # Phase execution should be created for the new phase
      pe = Executions.get_phase_execution_by_number(ws.id, 3)
      assert pe != nil
      assert pe.phase_name == "Task Description"
    end

    test "completes current phase execution before advancing" do
      ws = create_session_with_ai(%{current_phase: 3, total_phases: 6})
      {:ok, pe} = Executions.create_phase_execution(ws, 3, %{status: "awaiting_confirmation"})

      Engine.advance_to_next(ws)

      completed_pe = Executions.get_phase_execution!(pe.id)
      assert completed_pe.status == "completed"
      assert completed_pe.completed_at != nil
    end

    test "accepts workflow session id string" do
      ws = create_session_with_ai(%{current_phase: 2, total_phases: 6})

      Engine.advance_to_next(ws.id)

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.current_phase == 3
    end
  end
end
