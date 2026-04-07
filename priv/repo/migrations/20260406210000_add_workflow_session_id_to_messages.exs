defmodule Destila.Repo.Migrations.AddWorkflowSessionIdToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :workflow_session_id, references(:workflow_sessions, type: :binary_id, on_delete: :delete_all)
    end

    # Backfill from ai_sessions
    execute(
      "UPDATE messages SET workflow_session_id = (SELECT workflow_session_id FROM ai_sessions WHERE ai_sessions.id = messages.ai_session_id)",
      "UPDATE messages SET workflow_session_id = NULL"
    )

    # NOT NULL enforced at the application level via validate_required in the changeset.
    # SQLite does not support ALTER COLUMN to add NOT NULL after the fact.

    create index(:messages, [:workflow_session_id])
  end
end
