defmodule Destila.Repo.Migrations.AddSetupCommandToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :setup_command, :string
    end
  end
end
