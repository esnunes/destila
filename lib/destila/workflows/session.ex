defmodule Destila.Workflows.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "workflow_sessions" do
    field(:title, :string, default: "Untitled Session")
    field(:workflow_type, Ecto.Enum, values: [:brainstorm_idea, :implement_general_prompt])

    field(:current_phase, :integer, default: 1)
    field(:total_phases, :integer)

    field(:title_generating, :boolean, default: false)
    field(:position, :integer)
    field(:done_at, :utc_datetime)
    field(:archived_at, :utc_datetime)

    belongs_to(:project, Destila.Projects.Project)
    has_many(:ai_sessions, Destila.AI.Session, foreign_key: :workflow_session_id)
    has_many(:messages, Destila.AI.Message, foreign_key: :workflow_session_id)

    has_many(:phase_executions, Destila.Executions.PhaseExecution,
      foreign_key: :workflow_session_id
    )

    has_many(:metadata, Destila.Workflows.SessionMetadata, foreign_key: :workflow_session_id)

    timestamps(type: :utc_datetime)
  end

  def changeset(workflow_session, attrs) do
    workflow_session
    |> cast(attrs, [
      :title,
      :workflow_type,
      :project_id,
      :done_at,
      :current_phase,
      :total_phases,
      :title_generating,
      :position,
      :archived_at
    ])
    |> validate_required([:title, :workflow_type])
  end

  def done?(%__MODULE__{done_at: done_at}), do: not is_nil(done_at)

  def phase_status(%__MODULE__{} = ws) do
    if done?(ws), do: nil, else: Destila.Executions.current_status(ws.id)
  end
end
