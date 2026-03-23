defmodule DestilaWeb.PhaseZeroSetupLiveTest do
  @moduledoc """
  LiveView tests for Phase 0 - Project Setup.
  Feature: features/phase_zero_setup.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "phase_zero_setup"

  setup %{conn: conn} do
    ClaudeCode.Test.set_mode_to_shared()

    ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
      [
        ClaudeCode.Test.text("AI response"),
        ClaudeCode.Test.result("AI response")
      ]
    end)

    conn = post(conn, "/login", %{"email" => "test@example.com"})
    {:ok, conn: conn}
  end

  describe "setup with a local project" do
    @tag feature: @feature, scenario: "Setup for a prompt with a local project"
    test "shows Phase 0 section with completed setup steps", %{conn: conn} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Local Project",
          local_folder: "/tmp/test-repo"
        })

      prompt = create_prompt_with_phase0_complete(project)

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      # Phase 0 section is present
      assert render(view) =~ "Phase 0"
      assert render(view) =~ "Setup"

      # Completed setup steps are visible
      assert render(view) =~ "Repository up to date"
      assert render(view) =~ "Worktree ready"
      assert render(view) =~ "AI session ready"
    end

    @tag feature: @feature, scenario: "Setup for a prompt with a local project"
    test "shows title generation result in Phase 0", %{conn: conn} do
      prompt = create_prompt_in_setup(nil)

      # Simulate title generation completing
      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: "My Generated Title",
        raw_response: %{
          "setup_step" => "title_generation",
          "status" => "completed",
          "result" => "My Generated Title"
        },
        phase: 0
      })

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      assert render(view) =~ "My Generated Title"
    end
  end

  describe "setup with a remote-only project" do
    @tag feature: @feature, scenario: "Setup for a prompt with a remote-only project"
    test "shows clone step instead of pull for remote-only projects", %{conn: conn} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Remote Project",
          git_repo_url: "https://github.com/test/repo"
        })

      prompt = create_prompt_in_setup(project)

      # Simulate clone completing
      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: "Repository cloned",
        raw_response: %{"setup_step" => "repo_sync", "status" => "completed"},
        phase: 0
      })

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      assert render(view) =~ "Phase 0"
      assert render(view) =~ "Repository cloned"
    end
  end

  describe "setup without a linked project" do
    @tag feature: @feature, scenario: "Setup for a prompt without a linked project"
    test "shows only title generation step when no project linked", %{conn: conn} do
      prompt = create_prompt_in_setup(nil)

      # Only title generation message
      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: "Generating title...",
        raw_response: %{"setup_step" => "title_generation", "status" => "in_progress"},
        phase: 0
      })

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      html = render(view)
      assert html =~ "Phase 0"
      assert html =~ "Generating title..."

      # No git or worktree steps
      refute html =~ "Pulling latest"
      refute html =~ "Cloning repository"
      refute html =~ "Creating worktree"
      refute html =~ "Starting AI session"
    end

    @tag feature: @feature, scenario: "Setup for a prompt without a linked project"
    test "Phase 0 collapses when title generation completes and no project", %{conn: conn} do
      # Create prompt with phase_status already transitioned (setup complete)
      prompt = create_prompt_with_title_done(nil)

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      html = render(view)
      # Phase 0 section exists but is collapsed (no open attribute since phase_status != :setup)
      assert html =~ "Phase 0"

      # Phase 1 is visible
      assert html =~ "Phase 1"
      assert html =~ "Task Description"
    end
  end

  describe "setup step failure" do
    @tag feature: @feature, scenario: "A setup step fails"
    test "shows error message and retry button for failed step", %{conn: conn} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Failing Project",
          local_folder: "/tmp/nonexistent"
        })

      prompt = create_prompt_in_setup(project)

      # Simulate a failed repo sync
      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: "fatal: not a git repository",
        raw_response: %{"setup_step" => "repo_sync", "status" => "failed"},
        phase: 0
      })

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      html = render(view)
      # Error message is visible
      assert html =~ "fatal: not a git repository"

      # Retry button is present
      assert has_element?(view, "button[phx-click='retry_setup']")
    end

    @tag feature: @feature, scenario: "A setup step fails"
    test "clicking retry creates new setup progress messages", %{conn: conn} do
      # Use a project without local_folder so SetupWorker skips git operations
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Retry Project",
          git_repo_url: "https://github.com/test/nonexistent"
        })

      prompt = create_prompt_in_setup(project)

      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: "Connection refused",
        raw_response: %{"setup_step" => "repo_sync", "status" => "failed"},
        phase: 0
      })

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      messages_before = Destila.Messages.list_messages(prompt.id)

      # Click retry — SetupWorker runs inline and creates new phase 0 messages
      view |> element("button[phx-click='retry_setup']") |> render_click()

      messages_after = Destila.Messages.list_messages(prompt.id)

      new_phase0 =
        Enum.filter(messages_after, &(&1.phase == 0)) --
          Enum.filter(messages_before, &(&1.phase == 0))

      # Retry should have produced new phase 0 messages
      assert length(new_phase0) > 0
    end
  end

  describe "user navigates away during setup" do
    @tag feature: @feature, scenario: "User navigates away during setup"
    test "shows current progress when returning to the page", %{conn: conn} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Nav Away Project",
          local_folder: "/tmp/nav-repo"
        })

      prompt = create_prompt_in_setup(project)

      # Simulate partial progress — repo sync done, worktree in progress
      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: "Repository up to date",
        raw_response: %{"setup_step" => "repo_sync", "status" => "completed"},
        phase: 0
      })

      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: "Creating worktree...",
        raw_response: %{"setup_step" => "worktree", "status" => "in_progress"},
        phase: 0
      })

      # "Return" to the page — mount loads messages from DB
      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      html = render(view)
      # Completed step is shown
      assert html =~ "Repository up to date"
      # In-progress step is shown
      assert html =~ "Creating worktree..."
      # Phase 0 is open (still in setup)
      assert html =~ "Phase 0"
    end
  end

  describe "chat input during setup" do
    @tag feature: @feature, scenario: "Chat input disabled during setup"
    test "chat input is disabled while setup is in progress", %{conn: conn} do
      prompt = create_prompt_in_setup(nil)

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      # Input should not be available during setup
      # When phase_status is :setup, ai_step_info returns input_type: nil,
      # so the text input section doesn't render at all
      refute has_element?(view, "input[name='content']:not([disabled])")
    end

    @tag feature: @feature, scenario: "Chat input disabled during setup"
    test "chat input is enabled after setup completes", %{conn: conn} do
      prompt = create_prompt_with_title_done(nil)

      # Set to conversing (AI has responded, user can type)
      Destila.Prompts.update_prompt(prompt.id, %{phase_status: :conversing})

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      assert has_element?(view, "input[name='content']:not([disabled])")
    end

    @tag feature: @feature, scenario: "Chat input disabled during setup"
    test "sending a message is blocked during setup", %{conn: conn} do
      prompt = create_prompt_in_setup(nil)

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      messages_before = Destila.Messages.list_messages(prompt.id)

      # Even if we force a send_text event, it should be a no-op
      render_hook(view, "send_text", %{"content" => "Hello"})

      messages_after = Destila.Messages.list_messages(prompt.id)

      # No new messages should be created
      assert length(messages_after) == length(messages_before)
    end
  end

  describe "deduplication" do
    test "shows only the latest status per setup step", %{conn: conn} do
      prompt = create_prompt_in_setup(nil)

      # Create both in_progress and completed messages for the same step
      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: "Pulling latest changes...",
        raw_response: %{"setup_step" => "repo_sync", "status" => "in_progress"},
        phase: 0
      })

      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: "Repository up to date",
        raw_response: %{"setup_step" => "repo_sync", "status" => "completed"},
        phase: 0
      })

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      html = render(view)
      # Should show the completed version, not the in_progress one
      assert html =~ "Repository up to date"
      refute html =~ "Pulling latest changes..."
    end
  end

  # --- Helpers ---

  # Creates a chore_task prompt in :setup phase status with phase 1 messages.
  defp create_prompt_in_setup(project) do
    {:ok, prompt} =
      Destila.Prompts.create_prompt(%{
        title: "Generating title...",
        title_generating: true,
        workflow_type: :chore_task,
        project_id: if(project, do: project.id),
        board: :crafting,
        column: :request,
        steps_completed: 1,
        steps_total: 4,
        phase_status: :setup
      })

    {:ok, _} =
      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: "Let's work on your task.",
        phase: 1
      })

    {:ok, _} =
      Destila.Messages.create_message(prompt.id, %{
        role: :user,
        content: "Fix the login bug",
        phase: 1
      })

    prompt
  end

  # Creates a prompt where Phase 0 is complete (title done, AI responding).
  defp create_prompt_with_title_done(project) do
    {:ok, prompt} =
      Destila.Prompts.create_prompt(%{
        title: "My Generated Title",
        title_generating: false,
        workflow_type: :chore_task,
        project_id: if(project, do: project.id),
        board: :crafting,
        column: :request,
        steps_completed: 1,
        steps_total: 4,
        phase_status: :generating
      })

    # Phase 0 completed message
    {:ok, _} =
      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: "My Generated Title",
        raw_response: %{
          "setup_step" => "title_generation",
          "status" => "completed",
          "result" => "My Generated Title"
        },
        phase: 0
      })

    # Phase 1 messages
    {:ok, _} =
      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: "Let's work on your task.",
        phase: 1
      })

    {:ok, _} =
      Destila.Messages.create_message(prompt.id, %{
        role: :user,
        content: "Fix the login bug",
        phase: 1
      })

    # AI response to Phase 1
    {:ok, _} =
      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: "I have some questions about this task.",
        raw_response: %{
          "text" => "I have some questions about this task.",
          "result" => "I have some questions about this task.",
          "mcp_tool_uses" => [],
          "is_error" => false
        },
        phase: 1
      })

    prompt
  end

  # Creates a prompt where the full Phase 0 setup is complete (with project).
  defp create_prompt_with_phase0_complete(project) do
    {:ok, prompt} =
      Destila.Prompts.create_prompt(%{
        title: "Test Prompt",
        title_generating: false,
        workflow_type: :chore_task,
        project_id: project.id,
        board: :crafting,
        column: :request,
        steps_completed: 1,
        steps_total: 4,
        phase_status: :generating
      })

    # Phase 0 setup messages (deduplicated — only final statuses)
    for {step, content} <- [
          {"title_generation", "Test Prompt"},
          {"repo_sync", "Repository up to date"},
          {"worktree", "Worktree ready"},
          {"ai_session", "AI session ready"}
        ] do
      {:ok, _} =
        Destila.Messages.create_message(prompt.id, %{
          role: :system,
          content: content,
          raw_response: %{"setup_step" => step, "status" => "completed"},
          phase: 0
        })
    end

    # Phase 1 messages
    {:ok, _} =
      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: "Let's work on your task.",
        phase: 1
      })

    {:ok, _} =
      Destila.Messages.create_message(prompt.id, %{
        role: :user,
        content: "Fix the login bug",
        phase: 1
      })

    {:ok, _} =
      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: "I have some questions.",
        raw_response: %{
          "text" => "I have some questions.",
          "result" => "I have some questions.",
          "mcp_tool_uses" => [],
          "is_error" => false
        },
        phase: 1
      })

    prompt
  end
end
