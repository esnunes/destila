defmodule Destila.Messages.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "messages" do
    field(:role, Ecto.Enum, values: [:system, :user])
    field(:content, :string, default: "")
    field(:raw_response, :map)
    field(:selected, {:array, :string})
    field(:phase, :integer, default: 1)

    belongs_to(:workflow_session, Destila.WorkflowSessions.WorkflowSession)

    field(:inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []})
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :workflow_session_id,
      :role,
      :content,
      :raw_response,
      :selected,
      :phase
    ])
    |> validate_required([:workflow_session_id, :role])
    |> validate_number(:phase, greater_than_or_equal_to: 0)
  end
end
