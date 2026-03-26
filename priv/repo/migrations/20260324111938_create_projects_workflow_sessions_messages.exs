defmodule Destila.Repo.Migrations.CreateProjectsWorkflowSessionsMessages do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :git_repo_url, :string
      add :local_folder, :string

      timestamps(type: :utc_datetime)
    end

    create table(:workflow_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false, default: "Untitled Session"
      add :workflow_type, :string, null: false
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict)
      add :done_at, :utc_datetime
      add :current_phase, :integer, default: 1
      add :total_phases, :integer, null: false
      add :phase_status, :string
      add :title_generating, :boolean, default: false
      add :setup_steps, :map, default: %{}
      add :position, :integer, null: false
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:workflow_sessions, [:project_id])
    create index(:workflow_sessions, [:archived_at])

    create table(:ai_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workflow_session_id, references(:workflow_sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :claude_session_id, :string
      add :worktree_path, :string

      timestamps(type: :utc_datetime)
    end

    create index(:ai_sessions, [:workflow_session_id])

    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :ai_session_id, references(:ai_sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :content, :text, null: false, default: ""
      add :raw_response, :text
      add :selected, :text
      add :phase, :integer, default: 1

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:messages, [:ai_session_id, :inserted_at])
  end
end
