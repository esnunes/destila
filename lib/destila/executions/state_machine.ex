defmodule Destila.Executions.StateMachine do
  @moduledoc """
  Defines valid phase execution state transitions and provides
  a validated transition function.
  """

  alias Destila.Repo
  alias Destila.Executions.PhaseExecution

  @transitions %{
    pending: [:processing],
    processing: [:awaiting_input, :awaiting_confirmation, :completed, :skipped, :failed],
    awaiting_input: [:processing],
    awaiting_confirmation: [:completed, :awaiting_input],
    failed: [:processing],
    completed: [],
    skipped: []
  }

  @doc "Returns true if transitioning from `from` to `to` is allowed."
  def valid_transition?(from, to), do: to in Map.get(@transitions, from, [])

  @doc "Returns the list of states reachable from the given state."
  def allowed_transitions(state), do: Map.get(@transitions, state, [])

  @doc """
  Transitions a phase execution to a new status, persisting the change.

  Raises `ArgumentError` if the transition is invalid.
  Returns the updated `%PhaseExecution{}`.
  """
  def transition!(%PhaseExecution{status: from} = pe, to, attrs \\ %{}) do
    unless valid_transition?(from, to) do
      raise ArgumentError,
            "invalid phase execution transition: #{from} -> #{to} (pe: #{pe.id}, ws: #{pe.workflow_session_id})"
    end

    pe
    |> PhaseExecution.changeset(Map.put(attrs, :status, to))
    |> Repo.update!()
  end
end
