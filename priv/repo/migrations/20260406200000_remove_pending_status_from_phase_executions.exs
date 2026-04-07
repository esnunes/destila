defmodule Destila.Repo.Migrations.RemovePendingStatusFromPhaseExecutions do
  use Ecto.Migration

  def up do
    # Migrate any existing pending rows to processing.
    # The Ecto schema default handles new inserts; SQLite doesn't support ALTER COLUMN
    # so we only need the data migration.
    execute("UPDATE phase_executions SET status = 'processing' WHERE status = 'pending'")
  end

  def down do
    # No-op: the Ecto schema controls the default, not the DB column
    :ok
  end
end
