defmodule Destila.Repo.Migrations.RemovePhaseStatusFromWorkflowSessions do
  use Ecto.Migration

  def change do
    alter table(:workflow_sessions) do
      remove :phase_status, :string
    end
  end
end
