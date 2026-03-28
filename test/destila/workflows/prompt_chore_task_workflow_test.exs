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

  describe "wizard_validate_fields/1" do
    test "returns :ok when both fields are valid" do
      assert :ok =
               PromptChoreTaskWorkflow.wizard_validate_fields(%{
                 project_id: "some-id",
                 idea: "Fix the bug"
               })
    end

    test "returns error when project_id is nil" do
      assert {:error, errors} =
               PromptChoreTaskWorkflow.wizard_validate_fields(%{
                 project_id: nil,
                 idea: "Fix the bug"
               })

      assert errors[:project] == "Please select a project"
      refute Map.has_key?(errors, :idea)
    end

    test "returns error when idea is empty" do
      assert {:error, errors} =
               PromptChoreTaskWorkflow.wizard_validate_fields(%{
                 project_id: "some-id",
                 idea: ""
               })

      assert errors[:idea] == "Please describe your initial idea"
      refute Map.has_key?(errors, :project)
    end

    test "returns error when idea is nil" do
      assert {:error, errors} =
               PromptChoreTaskWorkflow.wizard_validate_fields(%{
                 project_id: "some-id",
                 idea: nil
               })

      assert errors[:idea] == "Please describe your initial idea"
    end

    test "returns both errors when both fields are invalid" do
      assert {:error, errors} =
               PromptChoreTaskWorkflow.wizard_validate_fields(%{
                 project_id: nil,
                 idea: ""
               })

      assert errors[:project]
      assert errors[:idea]
    end
  end

  describe "setup_initiate/2" do
    setup do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [ClaudeCode.Test.text("Generated Title")]
      end)

      :ok
    end

    test "is idempotent when phase_status is already :setup" do
      ws = create_session(%{phase_status: :setup})
      assert :ok = PromptChoreTaskWorkflow.setup_initiate(ws, %{})
    end

    test "sets phase_status to :setup" do
      ws = create_session(%{phase_status: nil})
      assert :ok = PromptChoreTaskWorkflow.setup_initiate(ws, %{})

      updated = Workflows.get_workflow_session!(ws.id)
      assert updated.phase_status == :setup
    end

    test "does not enqueue setup worker when no project" do
      ws = create_session(%{phase_status: nil, project_id: nil})
      PromptChoreTaskWorkflow.setup_initiate(ws, %{})

      refute_enqueued(worker: Destila.Workers.SetupWorker)
    end
  end

  describe "setup_retry/1" do
    setup do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [ClaudeCode.Test.text("Generated Title")]
      end)

      :ok
    end

    test "does not enqueue workers when not needed" do
      ws = create_session(%{project_id: nil, title_generating: false})
      PromptChoreTaskWorkflow.setup_retry(ws)

      refute_enqueued(worker: Destila.Workers.SetupWorker)
      refute_enqueued(worker: Destila.Workers.TitleGenerationWorker)
    end
  end

  describe "ai_conversation_send_user_message/3" do
    setup do
      ClaudeCode.Test.set_mode_to_shared()

      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [ClaudeCode.Test.text("AI response")]
      end)

      :ok
    end

    test "creates user message and updates status" do
      ws = create_session(%{phase_status: :conversing})
      {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

      {:ok, updated_ws} =
        PromptChoreTaskWorkflow.ai_conversation_send_user_message(ws, ai_session, "Hello AI")

      assert updated_ws.phase_status == :generating
      messages = Destila.AI.list_messages(ai_session.id)
      user_messages = Enum.filter(messages, &(&1.role == :user))
      assert length(user_messages) >= 1
    end

    test "returns error when already generating" do
      ws = create_session(%{phase_status: :generating})
      {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

      assert {:error, :generating} =
               PromptChoreTaskWorkflow.ai_conversation_send_user_message(ws, ai_session, "Hello")
    end
  end
end
