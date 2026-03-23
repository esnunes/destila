defmodule Destila.Prompts.Prompt do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "prompts" do
    field(:title, :string, default: "Untitled Prompt")

    field(:workflow_type, Ecto.Enum, values: [:feature_request, :chore_task, :project])

    field(:board, Ecto.Enum, values: [:crafting, :implementation])

    field(:column, Ecto.Enum,
      values: [:request, :distill, :done, :todo, :in_progress, :review, :qa, :impl_done]
    )

    field(:steps_completed, :integer, default: 0)
    field(:steps_total, :integer, default: 4)

    field(:phase_status, Ecto.Enum,
      values: [:setup, :generating, :conversing, :advance_suggested]
    )

    field(:title_generating, :boolean, default: false)
    field(:session_id, :string)
    field(:worktree_path, :string)
    field(:position, :integer)

    belongs_to(:project, Destila.Projects.Project)
    has_many(:messages, Destila.Messages.Message)

    timestamps(type: :utc_datetime)
  end

  def changeset(prompt, attrs) do
    prompt
    |> cast(attrs, [
      :title,
      :workflow_type,
      :project_id,
      :board,
      :column,
      :steps_completed,
      :steps_total,
      :phase_status,
      :title_generating,
      :session_id,
      :worktree_path,
      :position
    ])
    |> validate_required([:title, :workflow_type, :board, :column])
  end
end
