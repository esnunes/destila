defmodule Destila.Repo.Migrations.AddUserPromptToWorkflowSessions do
  use Ecto.Migration

  def up do
    alter table(:workflow_sessions) do
      add :user_prompt, :text
    end

    flush()

    # Backfill from creation-phase metadata, mapping workflow_type to the correct key
    execute """
    UPDATE workflow_sessions
    SET user_prompt = json_extract(m.value, '$.text')
    FROM workflow_session_metadata m
    WHERE m.workflow_session_id = workflow_sessions.id
      AND m.phase_name = 'creation'
      AND (
        (workflow_sessions.workflow_type = 'brainstorm_idea' AND m.key = 'idea')
        OR (workflow_sessions.workflow_type = 'code_chat' AND m.key = 'user_prompt')
        OR (workflow_sessions.workflow_type = 'implement_general_prompt' AND m.key = 'prompt')
      )
    """

    # Delete the old creation-phase metadata rows
    execute """
    DELETE FROM workflow_session_metadata
    WHERE phase_name = 'creation'
      AND key IN ('idea', 'user_prompt', 'prompt')
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
      CASE ws.workflow_type
        WHEN 'brainstorm_idea' THEN 'idea'
        WHEN 'code_chat' THEN 'user_prompt'
        WHEN 'implement_general_prompt' THEN 'prompt'
      END,
      json_object('text', ws.user_prompt),
      0,
      datetime('now'),
      datetime('now')
    FROM workflow_sessions ws
    WHERE ws.user_prompt IS NOT NULL
    """

    alter table(:workflow_sessions) do
      remove :user_prompt
    end
  end
end
