defmodule Destila.Repo.Migrations.AddExportedToSessionMetadata do
  use Ecto.Migration

  def change do
    alter table(:workflow_session_metadata) do
      add :exported, :boolean, default: false, null: false
    end
  end
end
