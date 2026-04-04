defmodule Destila.Repo.Migrations.ExtractCreateSessionLive do
  use Ecto.Migration

  def up do
    # 1. Decrement current_phase and total_phases by 2 for all sessions
    execute """
    UPDATE workflow_sessions
    SET current_phase = MAX(current_phase - 2, 1),
        total_phases = total_phases - 2
    """

    # 2. Sessions that were on old phase 1 (wizard) or old phase 2 (setup)
    #    are now at phase 1 with setup status
    execute """
    UPDATE workflow_sessions
    SET phase_status = 'setup'
    WHERE current_phase = 1 AND phase_status IN ('processing', 'awaiting_input')
    AND id IN (
      SELECT DISTINCT workflow_session_id FROM workflow_session_metadata
      WHERE phase_name IN ('wizard', 'Setup') AND key IN ('title_gen', 'repo_sync', 'worktree')
      AND json_extract(value, '$.status') != 'completed'
    )
    """

    # 3. Reassign wizard/setup metadata phase_name to "creation"
    execute """
    UPDATE workflow_session_metadata
    SET phase_name = 'creation'
    WHERE phase_name IN ('wizard', 'Setup')
    """

    # 4. Decrement phase numbers on all messages by 2 (min 1)
    execute """
    UPDATE messages
    SET phase = MAX(phase - 2, 1)
    WHERE ai_session_id IN (
      SELECT id FROM ai_sessions
    )
    """

    # 5. Delete wizard/setup phase executions (old phases 1-2) first
    execute """
    DELETE FROM phase_executions
    WHERE phase_number <= 2
    """

    # 6. Then decrement remaining phase_executions numbers by 2
    execute """
    UPDATE phase_executions
    SET phase_number = phase_number - 2
    """
  end

  def down do
    # Reverse: increment phases back by 2
    execute """
    UPDATE workflow_sessions
    SET current_phase = current_phase + 2,
        total_phases = total_phases + 2
    """

    execute """
    UPDATE workflow_session_metadata
    SET phase_name = 'wizard'
    WHERE phase_name = 'creation'
    AND key IN ('idea', 'prompt', 'source_session')
    """

    execute """
    UPDATE workflow_session_metadata
    SET phase_name = 'Setup'
    WHERE phase_name = 'creation'
    AND key IN ('title_gen', 'repo_sync', 'worktree')
    """

    execute """
    UPDATE messages
    SET phase = phase + 2
    WHERE ai_session_id IN (
      SELECT id FROM ai_sessions
    )
    """

    execute """
    UPDATE phase_executions
    SET phase_number = phase_number + 2
    """
  end
end
