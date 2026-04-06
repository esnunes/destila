defmodule Destila.Repo.Migrations.ConvertPhaseExecutionStatusToEnum do
  use Ecto.Migration

  def change do
    # No column changes needed: SQLite stores Ecto.Enum values as their string
    # representation, which matches the existing :string column type.
    # This migration exists to record the schema change in the migration history.
  end
end
