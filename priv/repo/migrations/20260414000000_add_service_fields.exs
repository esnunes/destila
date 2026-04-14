defmodule Destila.Repo.Migrations.AddServiceFields do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :run_command, :string
      add :port_definitions, :string, default: "[]"
    end

    alter table(:workflow_sessions) do
      add :service_state, :map
    end
  end
end
