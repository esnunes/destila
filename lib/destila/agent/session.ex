defmodule Destila.Agent.Session do
  @moduledoc """
  Ecto schema for `agent_sessions` — the MCP-driven session lifecycle row.

  The new agent path persists session lifecycle (current phase, host mode,
  status) and tool-call events here, in parallel with the existing chat path
  which uses `Destila.Workflows.Session`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "agent_sessions" do
    field(:workflow_name, :string)
    field(:current_phase_index, :integer, default: 0)
    field(:total_phases, :integer, default: 1)

    field(:host_mode, Ecto.Enum, values: [:embedded, :external])

    field(:status, Ecto.Enum,
      values: [:awaiting_agent, :active, :disconnected, :done],
      default: :awaiting_agent
    )

    field(:connected_at, :utc_datetime)
    field(:disconnected_at, :utc_datetime)
    field(:title, :string)
    field(:archived_at, :utc_datetime)
    field(:deleted_at, :utc_datetime)

    belongs_to(:project, Destila.Projects.Project)
    has_many(:events, Destila.Agent.SessionEvent, foreign_key: :agent_session_id)

    timestamps(type: :utc_datetime)
  end

  @required ~w(workflow_name host_mode total_phases)a
  @optional ~w(project_id current_phase_index status connected_at disconnected_at title archived_at deleted_at)a

  def changeset(session, attrs) do
    session
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:total_phases, greater_than: 0)
    |> assoc_constraint(:project)
  end
end
