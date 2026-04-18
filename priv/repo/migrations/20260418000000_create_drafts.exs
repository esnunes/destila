defmodule Destila.Repo.Migrations.CreateDrafts do
  use Ecto.Migration

  def change do
    create table(:drafts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :prompt, :text, null: false
      add :priority, :string, null: false
      add :position, :float, null: false
      add :archived_at, :utc_datetime
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:drafts, [:priority, :position])
    create index(:drafts, [:archived_at])
    create index(:drafts, [:project_id])
  end
end
