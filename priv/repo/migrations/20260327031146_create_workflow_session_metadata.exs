defmodule Destila.Repo.Migrations.CreateWorkflowSessionMetadata do
  use Ecto.Migration

  def change do
    create table(:workflow_session_metadata, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_session_id,
          references(:workflow_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :phase_name, :string, null: false
      add :key, :string, null: false
      add :value, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workflow_session_metadata, [:workflow_session_id, :phase_name, :key])
    create index(:workflow_session_metadata, [:workflow_session_id])

    alter table(:workflow_sessions) do
      remove :setup_steps
    end
  end
end
