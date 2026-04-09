defmodule Destila.Repo.Migrations.AddSourceSessionIdToWorkflowSessions do
  use Ecto.Migration

  def up do
    alter table(:workflow_sessions) do
      add :source_session_id, references(:workflow_sessions, type: :binary_id, on_delete: :nilify_all)
    end

    flush()

    # Backfill from creation-phase metadata
    execute """
    UPDATE workflow_sessions
    SET source_session_id = json_extract(m.value, '$.id')
    FROM workflow_session_metadata m
    WHERE m.workflow_session_id = workflow_sessions.id
      AND m.phase_name = 'creation'
      AND m.key = 'source_session'
    """

    # Delete the old metadata rows
    execute """
    DELETE FROM workflow_session_metadata
    WHERE phase_name = 'creation'
      AND key = 'source_session'
    """
  end

  def down do
    # Re-create metadata rows from the column
    execute """
    INSERT INTO workflow_session_metadata (id, workflow_session_id, phase_name, key, value, exported, inserted_at, updated_at)
    SELECT
      lower(hex(randomblob(16))),
      ws.id,
      'creation',
      'source_session',
      json_object('id', ws.source_session_id),
      0,
      datetime('now'),
      datetime('now')
    FROM workflow_sessions ws
    WHERE ws.source_session_id IS NOT NULL
    """

    alter table(:workflow_sessions) do
      remove :source_session_id
    end
  end
end
