defmodule Destila.ExecutionsTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.{Executions, Workflows}

  defp create_session do
    {:ok, ws} =
      Workflows.insert_workflow_session(%{
        title: "Test Session",
        workflow_type: :brainstorm_idea,
        current_phase: 1,
        total_phases: 4
      })

    ws
  end

  describe "create_phase_execution/3" do
    test "creates a phase execution with default status" do
      ws = create_session()
      {:ok, pe} = Executions.create_phase_execution(ws, 1)

      assert pe.workflow_session_id == ws.id
      assert pe.phase_number == 1
      assert pe.phase_name == "Task Description"
      assert pe.status == :processing
      assert pe.started_at != nil
      assert is_nil(pe.completed_at)
    end

    test "creates with custom attributes" do
      ws = create_session()

      {:ok, pe} =
        Executions.create_phase_execution(ws, 2, %{status: :processing})

      assert pe.status == :processing
    end

    test "enforces unique constraint on workflow_session_id + phase_number" do
      ws = create_session()
      {:ok, _} = Executions.create_phase_execution(ws, 3)
      {:error, changeset} = Executions.create_phase_execution(ws, 3)

      assert {"has already been taken", _} =
               changeset.errors[:workflow_session_id]
    end
  end

  describe "ensure_phase_execution/2" do
    test "creates if not exists" do
      ws = create_session()
      {:ok, pe} = Executions.ensure_phase_execution(ws, 3)
      assert pe.phase_number == 3
    end

    test "returns existing if already created" do
      ws = create_session()
      {:ok, pe1} = Executions.create_phase_execution(ws, 3)
      {:ok, pe2} = Executions.ensure_phase_execution(ws, 3)
      assert pe1.id == pe2.id
    end
  end

  describe "status transitions" do
    test "complete_phase sets status and completed_at" do
      ws = create_session()
      {:ok, pe} = Executions.create_phase_execution(ws, 3)
      {:ok, pe} = Executions.complete_phase(pe, %{"summary" => "done"})

      assert pe.status == :completed
      assert pe.result == %{"summary" => "done"}
      assert pe.completed_at != nil
    end

    test "await_confirmation and confirm_completion" do
      ws = create_session()
      {:ok, pe} = Executions.create_phase_execution(ws, 3)

      {:ok, pe} = Executions.await_confirmation(pe, %{"msg" => "ready"})
      assert pe.status == :awaiting_confirmation
      assert pe.staged_result == %{"msg" => "ready"}

      {:ok, pe} = Executions.confirm_completion(pe)
      assert pe.status == :completed
      assert pe.result == %{"msg" => "ready"}
    end

    test "await_confirmation and reject_completion" do
      ws = create_session()
      {:ok, pe} = Executions.create_phase_execution(ws, 3)

      {:ok, pe} = Executions.await_confirmation(pe, %{"msg" => "ready"})
      {:ok, pe} = Executions.reject_completion(pe)

      assert pe.status == :awaiting_input
      assert is_nil(pe.staged_result)
    end

    test "create_phase_execution sets started_at and processing status by default" do
      ws = create_session()
      {:ok, pe} = Executions.create_phase_execution(ws, 3)

      assert pe.status == :processing
      assert pe.started_at != nil
    end
  end

  describe "current_status/1" do
    test "returns :setup when no phase execution exists" do
      ws = create_session()
      assert Executions.current_status(ws.id) == :setup
    end

    test "returns :processing for processing PE (default status)" do
      ws = create_session()
      {:ok, _pe} = Executions.create_phase_execution(ws, 1)
      assert Executions.current_status(ws.id) == :processing
    end

    test "returns :processing for explicitly processing PE" do
      ws = create_session()
      {:ok, _pe} = Executions.create_phase_execution(ws, 1, %{status: :processing})
      assert Executions.current_status(ws.id) == :processing
    end

    test "returns :awaiting_input for awaiting_input PE" do
      ws = create_session()
      {:ok, _pe} = Executions.create_phase_execution(ws, 1, %{status: :awaiting_input})
      assert Executions.current_status(ws.id) == :awaiting_input
    end

    test "returns :awaiting_confirmation for awaiting_confirmation PE" do
      ws = create_session()
      {:ok, _pe} = Executions.create_phase_execution(ws, 1, %{status: :awaiting_confirmation})
      assert Executions.current_status(ws.id) == :awaiting_confirmation
    end

    test "returns :processing for failed PE" do
      ws = create_session()
      {:ok, _pe} = Executions.create_phase_execution(ws, 1)
      # Simulate failure by direct status set
      {:ok, _pe} = Executions.create_phase_execution(ws, 2, %{status: :failed})
      assert Executions.current_status(ws.id) == :processing
    end

    test "returns nil for completed PE" do
      ws = create_session()
      {:ok, _pe} = Executions.create_phase_execution(ws, 1, %{status: :completed})
      assert is_nil(Executions.current_status(ws.id))
    end

    test "returns status of highest phase number PE" do
      ws = create_session()
      {:ok, _pe1} = Executions.create_phase_execution(ws, 1, %{status: :completed})
      {:ok, _pe2} = Executions.create_phase_execution(ws, 2, %{status: :awaiting_input})
      assert Executions.current_status(ws.id) == :awaiting_input
    end
  end

  describe "queries" do
    test "get_current_phase_execution returns highest phase" do
      ws = create_session()
      {:ok, _} = Executions.create_phase_execution(ws, 2)
      {:ok, pe3} = Executions.create_phase_execution(ws, 3)

      current = Executions.get_current_phase_execution(ws.id)
      assert current.id == pe3.id
    end

    test "list_phase_executions returns ordered by phase_number" do
      ws = create_session()
      {:ok, _} = Executions.create_phase_execution(ws, 3)
      {:ok, _} = Executions.create_phase_execution(ws, 2)

      execs = Executions.list_phase_executions(ws.id)
      assert length(execs) == 2
      assert Enum.map(execs, & &1.phase_number) == [2, 3]
    end

    test "get_phase_execution_by_number returns correct execution" do
      ws = create_session()
      {:ok, pe} = Executions.create_phase_execution(ws, 4)

      found = Executions.get_phase_execution_by_number(ws.id, 4)
      assert found.id == pe.id

      assert is_nil(Executions.get_phase_execution_by_number(ws.id, 5))
    end
  end
end
