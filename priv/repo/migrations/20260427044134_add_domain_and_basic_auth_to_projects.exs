defmodule Destila.Repo.Migrations.AddDomainAndBasicAuthToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :domain, :string
      add :basic_auth_enabled, :boolean, null: false, default: false
    end
  end
end
