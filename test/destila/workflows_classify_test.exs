defmodule Destila.WorkflowsClassifyTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.{Executions, Workflows}

  defp create_session(attrs) do
    {pe_status, attrs} = Map.pop(attrs, :pe_status)

    default = %{
      title: "Test Session",
      workflow_type: :brainstorm_idea,
      current_phase: 1,
      total_phases: 4
    }

    {:ok, ws} = Workflows.insert_workflow_session(Map.merge(default, attrs))

    if pe_status do
      {:ok, _pe} = Executions.create_phase_execution(ws, ws.current_phase, %{status: pe_status})
    end

    ws
  end

  describe "classify/1" do
    test "returns :done for completed sessions" do
      ws = create_session(%{done_at: DateTime.utc_now()})
      assert Workflows.classify(ws) == :done
    end

    test "returns :processing for sessions with no PE (setup)" do
      ws = create_session(%{})
      assert Workflows.classify(ws) == :processing
    end

    test "returns :waiting_for_user when PE is awaiting_input" do
      ws = create_session(%{pe_status: :awaiting_input})
      assert Workflows.classify(ws) == :waiting_for_user
    end

    test "returns :waiting_for_user when PE is awaiting_confirmation" do
      ws = create_session(%{pe_status: :awaiting_confirmation})
      assert Workflows.classify(ws) == :waiting_for_user
    end

    test "returns :processing when PE is processing" do
      ws = create_session(%{pe_status: :processing})
      assert Workflows.classify(ws) == :processing
    end

    test "returns :processing when PE is completed" do
      ws = create_session(%{pe_status: :completed})
      assert Workflows.classify(ws) == :processing
    end
  end
end
