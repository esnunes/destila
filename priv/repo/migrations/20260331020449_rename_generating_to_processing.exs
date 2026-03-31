defmodule Destila.Repo.Migrations.RenameGeneratingToProcessing do
  use Ecto.Migration

  def up do
    execute "UPDATE workflow_sessions SET phase_status = 'processing' WHERE phase_status = 'generating'"
  end

  def down do
    execute "UPDATE workflow_sessions SET phase_status = 'generating' WHERE phase_status = 'processing'"
  end
end
