defmodule Destila.Repo.Migrations.AddCodeChatWorkflowType do
  use Ecto.Migration

  def change do
    # No column changes needed: SQLite stores Ecto.Enum values as their string
    # representation. This migration records the addition of :code_chat to
    # the workflow_type enum in the migration history.
  end
end
