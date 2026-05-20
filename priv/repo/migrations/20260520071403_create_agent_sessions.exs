defmodule Destila.Repo.Migrations.CreateAgentSessions do
  use Ecto.Migration

  def change do
    create table(:agent_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
      add :workflow_name, :string, null: false
      add :current_phase_index, :integer, null: false, default: 0
      add :total_phases, :integer, null: false, default: 1
      add :host_mode, :string, null: false
      add :status, :string, null: false, default: "awaiting_agent"
      add :connected_at, :utc_datetime
      add :disconnected_at, :utc_datetime
      add :title, :string
      add :archived_at, :utc_datetime
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:agent_sessions, [:status])
    create index(:agent_sessions, [:project_id])

    create table(:agent_session_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :agent_session_id,
          references(:agent_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :phase_index, :integer, null: false, default: 0
      add :tool_name, :string, null: false
      add :tool_input, :map
      add :tool_result, :map
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:agent_session_events, [:agent_session_id, :inserted_at])

    # Rebuild workflow_session_metadata to (a) make workflow_session_id nullable
    # and (b) add the nullable agent_session_id FK and phase_index column.
    # SQLite cannot ALTER NULL constraints in place, so we use a transactional
    # table-rebuild. The application-level changeset enforces that exactly one
    # of (workflow_session_id, agent_session_id) is set.
    execute(
      """
      CREATE TABLE workflow_session_metadata_new (
        id TEXT PRIMARY KEY,
        workflow_session_id TEXT REFERENCES workflow_sessions(id) ON DELETE CASCADE,
        agent_session_id TEXT REFERENCES agent_sessions(id) ON DELETE CASCADE,
        phase_name TEXT NOT NULL,
        phase_index INTEGER,
        key TEXT NOT NULL,
        value TEXT NOT NULL,
        exported INTEGER NOT NULL DEFAULT 0,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      "DROP TABLE workflow_session_metadata_new"
    )

    execute(
      """
      INSERT INTO workflow_session_metadata_new
        (id, workflow_session_id, phase_name, key, value, exported, inserted_at, updated_at)
      SELECT id, workflow_session_id, phase_name, key, value, exported, inserted_at, updated_at
      FROM workflow_session_metadata
      """,
      "SELECT 1"
    )

    execute(
      "DROP TABLE workflow_session_metadata",
      """
      CREATE TABLE workflow_session_metadata (
        id TEXT PRIMARY KEY,
        workflow_session_id TEXT NOT NULL REFERENCES workflow_sessions(id) ON DELETE CASCADE,
        phase_name TEXT NOT NULL,
        key TEXT NOT NULL,
        value TEXT NOT NULL,
        exported INTEGER NOT NULL DEFAULT 0,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """
    )

    execute(
      "ALTER TABLE workflow_session_metadata_new RENAME TO workflow_session_metadata",
      "SELECT 1"
    )

    create unique_index(:workflow_session_metadata, [:workflow_session_id, :phase_name, :key])
    create index(:workflow_session_metadata, [:workflow_session_id])
    create index(:workflow_session_metadata, [:agent_session_id])
  end
end
