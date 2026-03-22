defmodule Destila.Repo.Migrations.CreateProjectsPromptsMessages do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :git_repo_url, :string
      add :local_folder, :string

      timestamps(type: :utc_datetime)
    end

    create table(:prompts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false, default: "Untitled Prompt"
      add :workflow_type, :string, null: false
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict)
      add :board, :string, null: false
      add :column, :string, null: false
      add :steps_completed, :integer, default: 0
      add :steps_total, :integer, default: 4
      add :phase_status, :string
      add :title_generating, :boolean, default: false
      add :session_id, :string
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:prompts, [:project_id])
    create index(:prompts, [:board])

    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :prompt_id, references(:prompts, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :content, :text, null: false, default: ""
      add :raw_response, :text
      add :selected, :text
      add :phase, :integer, default: 1

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:messages, [:prompt_id])
  end
end
