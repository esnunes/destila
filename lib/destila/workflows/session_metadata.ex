defmodule Destila.Workflows.SessionMetadata do
  @moduledoc """
  Exports table shared by the chat path (`workflow_session_id`) and the new
  MCP-driven agent path (`agent_session_id`).

  Invariant: exactly one of `workflow_session_id` or `agent_session_id` is set.
  Enforced at the application layer via `changeset/2` because SQLite cannot
  cheaply add a CHECK constraint to the existing table.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "workflow_session_metadata" do
    field(:phase_name, :string)
    field(:phase_index, :integer)
    field(:key, :string)
    field(:value, :map)
    field(:exported, :boolean, default: false)

    belongs_to(:workflow_session, Destila.Workflows.Session)
    belongs_to(:agent_session, Destila.Agent.Session)

    timestamps(type: :utc_datetime)
  end

  def changeset(metadata, attrs) do
    metadata
    |> cast(attrs, [
      :workflow_session_id,
      :agent_session_id,
      :phase_name,
      :phase_index,
      :key,
      :value,
      :exported
    ])
    |> validate_required([:phase_name, :key, :value])
    |> validate_exactly_one_session()
  end

  defp validate_exactly_one_session(changeset) do
    ws = get_field(changeset, :workflow_session_id)
    as = get_field(changeset, :agent_session_id)

    case {ws, as} do
      {nil, nil} ->
        add_error(changeset, :workflow_session_id, "exactly one session FK must be set")

      {ws, as} when not is_nil(ws) and not is_nil(as) ->
        add_error(changeset, :workflow_session_id, "only one session FK may be set")

      _ ->
        changeset
    end
  end
end
