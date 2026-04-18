defmodule Destila.Drafts.Draft do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "drafts" do
    field(:prompt, :string)
    field(:priority, Ecto.Enum, values: [:low, :medium, :high])
    field(:position, :float)
    field(:archived_at, :utc_datetime)

    belongs_to(:project, Destila.Projects.Project)

    timestamps(type: :utc_datetime)
  end

  def changeset(draft, attrs) do
    draft
    |> cast(attrs, [:prompt, :priority, :position, :project_id, :archived_at])
    |> validate_required([:prompt, :priority, :position, :project_id])
    |> foreign_key_constraint(:project_id)
  end
end
