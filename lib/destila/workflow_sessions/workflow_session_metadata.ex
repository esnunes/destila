defmodule Destila.WorkflowSessions.WorkflowSessionMetadata do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "workflow_session_metadata" do
    field(:phase_name, :string)
    field(:key, :string)
    field(:value, :map)

    belongs_to(:workflow_session, Destila.WorkflowSessions.WorkflowSession)

    timestamps(type: :utc_datetime)
  end

  def changeset(metadata, attrs) do
    metadata
    |> cast(attrs, [:workflow_session_id, :phase_name, :key, :value])
    |> validate_required([:workflow_session_id, :phase_name, :key, :value])
  end
end
