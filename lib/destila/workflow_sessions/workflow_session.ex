defmodule Destila.WorkflowSessions.WorkflowSession do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "workflow_sessions" do
    field(:title, :string, default: "Untitled Session")

    field(:workflow_type, Ecto.Enum,
      values: [:prompt_chore_task, :prompt_new_project, :implement_generic_prompt]
    )

    field(:column, Ecto.Enum, values: [:request, :distill, :done])

    field(:steps_completed, :integer, default: 0)
    field(:steps_total, :integer, default: 4)

    field(:phase_status, Ecto.Enum,
      values: [:setup, :generating, :conversing, :advance_suggested]
    )

    field(:title_generating, :boolean, default: false)
    field(:ai_session_id, :string)
    field(:worktree_path, :string)
    field(:position, :integer)
    field(:archived_at, :utc_datetime)

    belongs_to(:project, Destila.Projects.Project)
    has_many(:messages, Destila.Messages.Message)

    timestamps(type: :utc_datetime)
  end

  def changeset(workflow_session, attrs) do
    workflow_session
    |> cast(attrs, [
      :title,
      :workflow_type,
      :project_id,
      :column,
      :steps_completed,
      :steps_total,
      :phase_status,
      :title_generating,
      :ai_session_id,
      :worktree_path,
      :position,
      :archived_at
    ])
    |> validate_required([:title, :workflow_type, :column])
  end
end
