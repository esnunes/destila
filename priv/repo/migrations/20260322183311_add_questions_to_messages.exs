defmodule Destila.Repo.Migrations.AddQuestionsToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :questions, :text
    end
  end
end
