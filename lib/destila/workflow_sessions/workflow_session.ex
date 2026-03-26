defmodule Destila.WorkflowSessions.WorkflowSession do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "workflow_sessions" do
    field(:title, :string, default: "Untitled Session")
    field(:workflow_type, Ecto.Enum, values: [:prompt_chore_task])

    field(:current_phase, :integer, default: 1)
    field(:total_phases, :integer)

    field(:phase_status, Ecto.Enum,
      values: [:setup, :generating, :conversing, :advance_suggested]
    )

    field(:title_generating, :boolean, default: false)
    field(:setup_steps, :map, default: %{})
    field(:position, :integer)
    field(:done_at, :utc_datetime)
    field(:archived_at, :utc_datetime)

    belongs_to(:project, Destila.Projects.Project)
    has_many(:ai_sessions, Destila.AI.Session)

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
      :phase_status,
      :title_generating,
      :setup_steps,
      :position,
      :archived_at
    ])
    |> validate_required([:title, :workflow_type])
  end

  def done?(%__MODULE__{done_at: done_at}), do: not is_nil(done_at)
end
