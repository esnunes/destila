defmodule Destila.Executions do
  @moduledoc """
  Context for phase execution lifecycle management.

  Provides CRUD and state-transition functions for `PhaseExecution` records,
  which track the status and result of each phase within a workflow session.
  """

  import Ecto.Query

  alias Destila.Repo
  alias Destila.Executions.PhaseExecution
  alias Destila.Executions.StateMachine

  # --- Queries ---

  def get_phase_execution!(id) do
    Repo.get!(PhaseExecution, id)
  end

  def get_current_phase_execution(workflow_session_id) do
    Repo.one(
      from(pe in PhaseExecution,
        where: pe.workflow_session_id == ^workflow_session_id,
        order_by: [desc: pe.phase_number],
        limit: 1
      )
    )
  end

  def get_phase_execution_by_number(workflow_session_id, phase_number) do
    Repo.one(
      from(pe in PhaseExecution,
        where:
          pe.workflow_session_id == ^workflow_session_id and
            pe.phase_number == ^phase_number
      )
    )
  end

  def list_phase_executions(workflow_session_id) do
    Repo.all(
      from(pe in PhaseExecution,
        where: pe.workflow_session_id == ^workflow_session_id,
        order_by: pe.phase_number
      )
    )
  end

  # --- Mutations ---

  def create_phase_execution(workflow_session, phase_number, attrs \\ %{}) do
    phase_name =
      Destila.Workflows.phase_name(workflow_session.workflow_type, phase_number) ||
        "Phase #{phase_number}"

    %PhaseExecution{}
    |> PhaseExecution.changeset(
      Map.merge(
        %{
          workflow_session_id: workflow_session.id,
          phase_number: phase_number,
          phase_name: phase_name,
          status: :pending
        },
        attrs
      )
    )
    |> Repo.insert()
  end

  def process_phase(%PhaseExecution{} = pe) do
    StateMachine.transition(pe, :processing)
  end

  def await_input(%PhaseExecution{} = pe) do
    StateMachine.transition(pe, :awaiting_input)
  end

  def complete_phase(%PhaseExecution{} = pe, result \\ nil) do
    StateMachine.transition(pe, :completed, %{
      result: result,
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  def await_confirmation(%PhaseExecution{} = pe, result) do
    StateMachine.transition(pe, :awaiting_confirmation, %{staged_result: result})
  end

  def confirm_completion(%PhaseExecution{} = pe) do
    StateMachine.transition(pe, :completed, %{
      result: pe.staged_result,
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  def reject_completion(%PhaseExecution{} = pe) do
    StateMachine.transition(pe, :awaiting_input, %{staged_result: nil})
  end

  def skip_phase(%PhaseExecution{} = pe, reason \\ nil) do
    StateMachine.transition(pe, :skipped, %{
      result: if(reason, do: %{"reason" => reason}, else: nil),
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  def start_phase(%PhaseExecution{} = pe, status \\ :processing) do
    StateMachine.transition(pe, status, %{
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  @doc """
  Gets or creates a phase execution for a given workflow session and phase number.
  Used for backwards compatibility during the migration period.
  """
  def ensure_phase_execution(workflow_session, phase_number) do
    case get_phase_execution_by_number(workflow_session.id, phase_number) do
      nil -> create_phase_execution(workflow_session, phase_number)
      pe -> {:ok, pe}
    end
  end
end
