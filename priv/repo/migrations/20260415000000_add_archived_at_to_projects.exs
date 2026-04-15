defmodule Destila.Repo.Migrations.AddArchivedAtToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :archived_at, :utc_datetime
    end

    create index(:projects, [:archived_at])
  end
end
