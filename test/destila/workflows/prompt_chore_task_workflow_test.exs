defmodule Destila.Workflows.PromptChoreTaskWorkflowTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.Workflows
  alias Destila.Workflows.PromptChoreTaskWorkflow

  defp create_session(attrs) do
    defaults = %{
      title: "Test Session",
      workflow_type: :prompt_chore_task,
      current_phase: 2,
      total_phases: 6
    }

    {:ok, ws} = Workflows.create_workflow_session(Map.merge(defaults, attrs))
    ws
  end

  describe "validate_wizard_fields/1" do
    test "returns :ok when both fields are valid" do
      assert :ok =
               PromptChoreTaskWorkflow.validate_wizard_fields(%{
                 project_id: "some-id",
                 idea: "Fix the bug"
               })
    end

    test "returns error when project_id is nil" do
      assert {:error, errors} =
               PromptChoreTaskWorkflow.validate_wizard_fields(%{
                 project_id: nil,
                 idea: "Fix the bug"
               })

      assert errors[:project] == "Please select a project"
      refute Map.has_key?(errors, :idea)
    end

    test "returns error when idea is empty" do
      assert {:error, errors} =
               PromptChoreTaskWorkflow.validate_wizard_fields(%{
                 project_id: "some-id",
                 idea: ""
               })

      assert errors[:idea] == "Please describe your initial idea"
      refute Map.has_key?(errors, :project)
    end

    test "returns error when idea is nil" do
      assert {:error, errors} =
               PromptChoreTaskWorkflow.validate_wizard_fields(%{
                 project_id: "some-id",
                 idea: nil
               })

      assert errors[:idea] == "Please describe your initial idea"
    end

    test "returns both errors when both fields are invalid" do
      assert {:error, errors} =
               PromptChoreTaskWorkflow.validate_wizard_fields(%{
                 project_id: nil,
                 idea: ""
               })

      assert errors[:project]
      assert errors[:idea]
    end
  end

  describe "validate_and_create_project/1" do
    test "creates project when params are valid" do
      assert {:ok, project} =
               PromptChoreTaskWorkflow.validate_and_create_project(%{
                 "name" => "My Project",
                 "git_repo_url" => "https://github.com/org/repo",
                 "local_folder" => ""
               })

      assert project.name == "My Project"
      assert project.git_repo_url == "https://github.com/org/repo"
    end

    test "creates project with local_folder only" do
      assert {:ok, project} =
               PromptChoreTaskWorkflow.validate_and_create_project(%{
                 "name" => "Local Project",
                 "git_repo_url" => "",
                 "local_folder" => "/home/user/project"
               })

      assert project.local_folder == "/home/user/project"
      assert project.git_repo_url == nil
    end

    test "returns error when name is empty" do
      assert {:error, errors} =
               PromptChoreTaskWorkflow.validate_and_create_project(%{
                 "name" => "",
                 "git_repo_url" => "https://github.com/org/repo",
                 "local_folder" => ""
               })

      assert errors[:name] == "Name is required"
    end

    test "returns error when both location fields are empty" do
      assert {:error, errors} =
               PromptChoreTaskWorkflow.validate_and_create_project(%{
                 "name" => "My Project",
                 "git_repo_url" => "",
                 "local_folder" => ""
               })

      assert errors[:location] == "Provide at least one"
    end

    test "trims whitespace from name" do
      assert {:ok, project} =
               PromptChoreTaskWorkflow.validate_and_create_project(%{
                 "name" => "  Trimmed  ",
                 "git_repo_url" => "",
                 "local_folder" => "/tmp"
               })

      assert project.name == "Trimmed"
    end
  end

  describe "initiate_setup/2" do
    setup do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [ClaudeCode.Test.text("Generated Title")]
      end)

      :ok
    end

    test "is idempotent when phase_status is already :setup" do
      ws = create_session(%{phase_status: :setup})
      assert :ok = PromptChoreTaskWorkflow.initiate_setup(ws, %{})
    end

    test "sets phase_status to :setup" do
      ws = create_session(%{phase_status: nil})
      assert :ok = PromptChoreTaskWorkflow.initiate_setup(ws, %{})

      updated = Workflows.get_workflow_session!(ws.id)
      assert updated.phase_status == :setup
    end

    test "does not enqueue setup worker when no project" do
      ws = create_session(%{phase_status: nil, project_id: nil})
      PromptChoreTaskWorkflow.initiate_setup(ws, %{})

      refute_enqueued(worker: Destila.Workers.SetupWorker)
    end
  end

  describe "retry_setup/1" do
    setup do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [ClaudeCode.Test.text("Generated Title")]
      end)

      :ok
    end

    test "does not enqueue workers when not needed" do
      ws = create_session(%{project_id: nil, title_generating: false})
      PromptChoreTaskWorkflow.retry_setup(ws)

      refute_enqueued(worker: Destila.Workers.SetupWorker)
      refute_enqueued(worker: Destila.Workers.TitleGenerationWorker)
    end
  end
end
