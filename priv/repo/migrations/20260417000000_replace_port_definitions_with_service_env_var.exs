defmodule Destila.Repo.Migrations.ReplacePortDefinitionsWithServiceEnvVar do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      remove :port_definitions
      add :service_env_var, :string
    end
  end
end
