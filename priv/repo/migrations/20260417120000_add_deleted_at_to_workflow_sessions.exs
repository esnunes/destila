defmodule Destila.Repo.Migrations.AddDeletedAtToWorkflowSessions do
  use Ecto.Migration

  def change do
    alter table(:workflow_sessions) do
      add :deleted_at, :utc_datetime
    end

    create index(:workflow_sessions, [:deleted_at])
  end
end
