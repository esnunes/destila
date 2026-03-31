defmodule Destila.WorkflowsClassifyTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.{Executions, Workflows}

  defp create_session(attrs) do
    default = %{
      title: "Test Session",
      workflow_type: :prompt_chore_task,
      current_phase: 3,
      total_phases: 6,
      phase_status: :awaiting_input
    }

    {:ok, ws} = Workflows.create_workflow_session(Map.merge(default, attrs))
    ws
  end

  describe "classify/1" do
    test "returns :done for completed sessions" do
      ws = create_session(%{done_at: DateTime.utc_now()})
      assert Workflows.classify(ws) == :done
    end

    test "returns :setup for sessions in setup phase_status" do
      ws = create_session(%{phase_status: :setup})
      assert Workflows.classify(ws) == :setup
    end

    test "returns :waiting_for_user when phase execution is awaiting_input" do
      ws = create_session(%{phase_status: nil})
      Executions.create_phase_execution(ws, 3, %{status: "awaiting_input"})
      assert Workflows.classify(ws) == :waiting_for_user
    end

    test "returns :waiting_for_user when phase execution is awaiting_confirmation" do
      ws = create_session(%{phase_status: nil})
      Executions.create_phase_execution(ws, 3, %{status: "awaiting_confirmation"})
      assert Workflows.classify(ws) == :waiting_for_user
    end

    test "returns :ai_processing when phase execution is processing" do
      ws = create_session(%{phase_status: nil})
      Executions.create_phase_execution(ws, 3, %{status: "processing"})
      assert Workflows.classify(ws) == :ai_processing
    end

    test "falls back to phase_status when no phase execution exists" do
      ws = create_session(%{phase_status: :awaiting_input})
      assert Workflows.classify(ws) == :waiting_for_user
    end

    test "falls back to phase_status :processing when no phase execution exists" do
      ws = create_session(%{phase_status: :processing})
      assert Workflows.classify(ws) == :ai_processing
    end

    test "falls back to :in_progress when no phase execution and nil phase_status" do
      ws = create_session(%{phase_status: nil})
      assert Workflows.classify(ws) == :in_progress
    end
  end
end
