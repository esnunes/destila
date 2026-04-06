defmodule Destila.Executions.PhaseExecution do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "phase_executions" do
    field(:phase_number, :integer)
    field(:phase_name, :string)

    field(:status, Ecto.Enum,
      values: [
        :pending,
        :processing,
        :awaiting_input,
        :awaiting_confirmation,
        :completed,
        :failed
      ],
      default: :pending
    )

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
    |> unique_constraint([:workflow_session_id, :phase_number])
  end
end
