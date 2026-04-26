defmodule Destila.Repo.Migrations.AddMessageTypeToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :message_type, :string
    end
  end
end
