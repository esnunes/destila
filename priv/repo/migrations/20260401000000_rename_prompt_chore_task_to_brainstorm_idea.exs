defmodule Destila.Repo.Migrations.RenamePromptChoreTaskToBrainstormIdea do
  use Ecto.Migration

  def up do
    execute "UPDATE workflow_sessions SET workflow_type = 'brainstorm_idea' WHERE workflow_type = 'prompt_chore_task'"
  end

  def down do
    execute "UPDATE workflow_sessions SET workflow_type = 'prompt_chore_task' WHERE workflow_type = 'brainstorm_idea'"
  end
end
