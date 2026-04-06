defmodule Destila.Executions.StateMachineTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.Executions
  alias Destila.Executions.StateMachine

  defp create_session do
    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test Session",
        workflow_type: :brainstorm_idea,
        current_phase: 1,
        total_phases: 4
      })

    ws
  end

  defp create_pe(ws, phase_number, attrs \\ %{}) do
    {:ok, pe} = Executions.create_phase_execution(ws, phase_number, attrs)
    pe
  end

  describe "valid_transition?/2" do
    test "allows valid transitions" do
      assert StateMachine.valid_transition?(:pending, :processing)
      assert StateMachine.valid_transition?(:pending, :completed)
      assert StateMachine.valid_transition?(:pending, :skipped)
      assert StateMachine.valid_transition?(:processing, :awaiting_input)
      assert StateMachine.valid_transition?(:processing, :awaiting_confirmation)
      assert StateMachine.valid_transition?(:processing, :completed)
      assert StateMachine.valid_transition?(:processing, :skipped)
      assert StateMachine.valid_transition?(:processing, :failed)
      assert StateMachine.valid_transition?(:awaiting_input, :processing)
      assert StateMachine.valid_transition?(:awaiting_input, :completed)
      assert StateMachine.valid_transition?(:awaiting_input, :skipped)
      assert StateMachine.valid_transition?(:awaiting_confirmation, :completed)
      assert StateMachine.valid_transition?(:awaiting_confirmation, :awaiting_input)
      assert StateMachine.valid_transition?(:failed, :processing)
      assert StateMachine.valid_transition?(:failed, :completed)
      assert StateMachine.valid_transition?(:failed, :skipped)
    end

    test "rejects invalid transitions" do
      refute StateMachine.valid_transition?(:pending, :awaiting_input)
      refute StateMachine.valid_transition?(:completed, :processing)
      refute StateMachine.valid_transition?(:skipped, :processing)
    end
  end

  describe "allowed_transitions/1" do
    test "returns reachable states for processing" do
      assert StateMachine.allowed_transitions(:processing) == [
               :awaiting_input,
               :awaiting_confirmation,
               :completed,
               :skipped,
               :failed
             ]
    end

    test "returns empty list for terminal states" do
      assert StateMachine.allowed_transitions(:completed) == []
      assert StateMachine.allowed_transitions(:skipped) == []
    end

    test "returns empty list for unknown states" do
      assert StateMachine.allowed_transitions(:nonexistent) == []
    end
  end

  describe "transition/3 happy paths" do
    test "pending -> processing with started_at" do
      ws = create_session()
      pe = create_pe(ws, 1)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, updated} = StateMachine.transition(pe, :processing, %{started_at: now})

      assert updated.status == :processing
      assert updated.started_at == now
    end

    test "processing -> completed with result and completed_at" do
      ws = create_session()
      pe = create_pe(ws, 1, %{status: :processing})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, updated} =
        StateMachine.transition(pe, :completed, %{
          result: %{"summary" => "done"},
          completed_at: now
        })

      assert updated.status == :completed
      assert updated.result == %{"summary" => "done"}
      assert updated.completed_at == now
    end

    test "awaiting_confirmation -> awaiting_input clears staged_result" do
      ws = create_session()
      pe = create_pe(ws, 1, %{status: :awaiting_confirmation, staged_result: %{"data" => "x"}})

      {:ok, updated} = StateMachine.transition(pe, :awaiting_input, %{staged_result: nil})

      assert updated.status == :awaiting_input
      assert is_nil(updated.staged_result)
    end

    test "failed -> processing for retry" do
      ws = create_session()
      pe = create_pe(ws, 1, %{status: :failed})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, updated} = StateMachine.transition(pe, :processing, %{started_at: now})

      assert updated.status == :processing
      assert updated.started_at == now
    end
  end

  describe "transition/3 invalid transitions" do
    test "completed -> processing returns error" do
      ws = create_session()
      pe = create_pe(ws, 1, %{status: :completed})

      assert {:error, message} = StateMachine.transition(pe, :processing)
      assert message =~ "invalid phase execution transition: completed -> processing"
    end

    test "pending -> awaiting_input returns error" do
      ws = create_session()
      pe = create_pe(ws, 1)

      assert {:error, message} = StateMachine.transition(pe, :awaiting_input)
      assert message =~ "invalid phase execution transition: pending -> awaiting_input"
    end

    test "skipped -> processing returns error (terminal)" do
      ws = create_session()
      pe = create_pe(ws, 1, %{status: :skipped})

      assert {:error, message} = StateMachine.transition(pe, :processing)
      assert message =~ "invalid phase execution transition"
    end
  end

  describe "transition/3 with attrs" do
    test "persists additional attributes alongside status change" do
      ws = create_session()
      pe = create_pe(ws, 1, %{status: :processing})

      {:ok, updated} =
        StateMachine.transition(pe, :awaiting_confirmation, %{
          staged_result: %{"output" => "result data"}
        })

      assert updated.status == :awaiting_confirmation
      assert updated.staged_result == %{"output" => "result data"}

      # Verify persistence by reloading
      reloaded = Executions.get_phase_execution!(updated.id)
      assert reloaded.staged_result == %{"output" => "result data"}
    end
  end
end
