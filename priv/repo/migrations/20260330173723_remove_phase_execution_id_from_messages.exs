defmodule Destila.Repo.Migrations.RemovePhaseExecutionIdFromMessages do
  use Ecto.Migration

  def change do
    drop index(:messages, [:phase_execution_id])

    alter table(:messages) do
      remove :phase_execution_id, references(:phase_executions, type: :binary_id)
    end
  end
end
