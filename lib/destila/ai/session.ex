defmodule Destila.AI.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "ai_sessions" do
    field(:claude_session_id, :string)
    field(:worktree_path, :string)

    belongs_to(:workflow_session, Destila.Workflows.Session)
    has_many(:messages, Destila.AI.Message, foreign_key: :ai_session_id)

    timestamps(type: :utc_datetime)
  end

  def changeset(ai_session, attrs) do
    ai_session
    |> cast(attrs, [:workflow_session_id, :claude_session_id, :worktree_path])
    |> validate_required([:workflow_session_id])
  end
end
