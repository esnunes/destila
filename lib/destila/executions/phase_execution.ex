defmodule Destila.Executions.PhaseExecution do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending awaiting_input processing awaiting_confirmation completed skipped failed)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "phase_executions" do
    field(:phase_number, :integer)
    field(:phase_name, :string)
    field(:status, :string, default: "pending")
    field(:result, :map)
    field(:staged_result, :map)
    field(:started_at, :utc_datetime)
    field(:completed_at, :utc_datetime)

    belongs_to(:workflow_session, Destila.Workflows.Session)

    timestamps(type: :utc_datetime)
  end

  def changeset(phase_execution, attrs) do
    phase_execution
    |> cast(attrs, [
      :workflow_session_id,
      :phase_number,
      :phase_name,
      :status,
      :result,
      :staged_result,
      :started_at,
      :completed_at
    ])
    |> validate_required([:workflow_session_id, :phase_number, :phase_name, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:workflow_session_id, :phase_number])
  end

  def statuses, do: @statuses
end
