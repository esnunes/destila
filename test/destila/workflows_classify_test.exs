defmodule Destila.WorkflowsClassifyTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.Workflows

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

  describe "classify/1" do
    test "returns :done for completed sessions" do
      ws = create_session(%{done_at: DateTime.utc_now()})
      assert Workflows.classify(ws) == :done
    end

    test "returns :processing for sessions in setup phase_status" do
      ws = create_session(%{phase_status: :setup})
      assert Workflows.classify(ws) == :processing
    end

    test "returns :waiting_for_user when phase_status is awaiting_input" do
      ws = create_session(%{phase_status: :awaiting_input})
      assert Workflows.classify(ws) == :waiting_for_user
    end

    test "returns :waiting_for_user when phase_status is advance_suggested" do
      ws = create_session(%{phase_status: :advance_suggested})
      assert Workflows.classify(ws) == :waiting_for_user
    end

    test "returns :processing when phase_status is processing" do
      ws = create_session(%{phase_status: :processing})
      assert Workflows.classify(ws) == :processing
    end

    test "returns :processing when phase_status is nil" do
      ws = create_session(%{phase_status: nil})
      assert Workflows.classify(ws) == :processing
    end
  end
end
