defmodule Destila.Repo.Migrations.AddServiceStateToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :service_state, :map
    end
  end
end
