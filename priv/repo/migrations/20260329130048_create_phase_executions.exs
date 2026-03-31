defmodule Destila.Repo.Migrations.CreatePhaseExecutions do
  use Ecto.Migration

  def change do
    create table(:phase_executions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_session_id,
          references(:workflow_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :phase_number, :integer, null: false
      add :phase_name, :string, null: false

      add :status, :string, null: false, default: "pending"

      add :result, :map
      add :staged_result, :map
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:phase_executions, [:workflow_session_id])
    create unique_index(:phase_executions, [:workflow_session_id, :phase_number])

    alter table(:messages) do
      add :phase_execution_id,
          references(:phase_executions, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:messages, [:phase_execution_id])
  end
end
