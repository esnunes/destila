defmodule Destila.Repo.Migrations.RenameConversingToAwaitingInput do
  use Ecto.Migration

  def up do
    execute "UPDATE workflow_sessions SET phase_status = 'awaiting_input' WHERE phase_status = 'conversing'"
  end

  def down do
    execute "UPDATE workflow_sessions SET phase_status = 'conversing' WHERE phase_status = 'awaiting_input'"
  end
end
