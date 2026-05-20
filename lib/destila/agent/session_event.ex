defmodule Destila.Agent.SessionEvent do
  @moduledoc """
  Ecto schema for `agent_session_events` — the tool-call event log.

  Only tool calls are recorded here. The new agent path never persists or
  parses agent assistant text.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "agent_session_events" do
    field(:phase_index, :integer, default: 0)
    field(:tool_name, :string)
    field(:tool_input, :map)
    field(:tool_result, :map)
    field(:inserted_at, :utc_datetime)

    belongs_to(:agent_session, Destila.Agent.Session)
  end

  @required ~w(agent_session_id tool_name)a
  @optional ~w(phase_index tool_input tool_result inserted_at)a

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> assoc_constraint(:agent_session)
  end
end
