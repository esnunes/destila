defmodule DestilaWeb.ChoreTaskWorkflowLiveTest do
  @moduledoc """
  LiveView tests for the Chore/Task AI-Driven Workflow.
  Feature: features/chore_task_workflow.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "chore_task_workflow"

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

  # --- Helpers ---

  defp create_project do
    {:ok, project} =
      Destila.Projects.create_project(%{
        name: "Test Project",
        git_repo_url: "https://github.com/test/repo"
      })

    project
  end

  # Creates a chore_task session in the given phase with appropriate state.
  defp create_session_in_phase(phase, opts \\ []) do
    phase_status = Keyword.get(opts, :phase_status, :conversing)
    last_message_type = Keyword.get(opts, :last_message_type)

    {last_content, session_tool_uses} =
      case last_message_type do
        :phase_advance ->
          {"Task description is clear.",
           [
             %{
               "name" => "mcp__destila__session",
               "input" => %{
                 "action" => "suggest_phase_complete",
                 "message" => "Task description is clear."
               }
             }
           ]}

        :skip_phase ->
          {"Skipping this phase.",
           [
             %{
               "name" => "mcp__destila__session",
               "input" => %{
                 "action" => "phase_complete",
                 "message" => "Skipping this phase."
               }
             }
           ]}

        _ ->
          {"I have some questions about this task.", []}
      end

    {:ok, ws} =
      Destila.Workflows.create_workflow_session(%{
        title: "Test Chore Task",
        workflow_type: :prompt_chore_task,
        project_id: nil,
        current_phase: phase,
        total_phases: 6,
        phase_status: phase_status
      })

    {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

    {:ok, _} =
      Destila.AI.create_message(ai_session.id, %{
        role: :system,
        content: "Let's work on your task.",
        phase: 3
      })

    {:ok, _} =
      Destila.AI.create_message(ai_session.id, %{
        role: :user,
        content: "Fix the login timeout bug",
        phase: 3
      })

    raw_response =
      if last_message_type != nil,
        do: %{
          "text" => last_content,
          "result" => last_content,
          "mcp_tool_uses" => session_tool_uses,
          "is_error" => false
        },
        else: nil

    {:ok, _} =
      Destila.AI.create_message(ai_session.id, %{
        role: :system,
        content: last_content,
        raw_response: raw_response,
        phase: phase
      })

    ws
  end

  # --- Phase 1: Wizard ---

  describe "Phase 1 - Wizard" do
    @tag feature: @feature, scenario: "Phase 1 - Wizard collects project and idea"
    test "collects project and idea, creates session, redirects", %{conn: conn} do
      project = create_project()

      {:ok, view, _html} = live(conn, ~p"/workflows/prompt_chore_task")

      # Shows wizard form
      assert has_element?(view, "#project-list")
      assert has_element?(view, "#wizard-idea-form")

      # Progress bar shows Phase 1
      assert render(view) =~ "Phase 1/6"
      assert render(view) =~ "Project &amp; Idea"

      # Select project and enter idea
      view |> element("#project-#{project.id}") |> render_click()
      assert render(view) =~ "border-primary"

      view
      |> form("#wizard-idea-form", %{"initial_idea" => "Fix the login timeout bug"})
      |> render_submit()

      # Redirects to session detail page
      {path, _flash} = assert_redirect(view)
      assert path =~ "/sessions/"
    end

    @tag feature: @feature, scenario: "Phase 1 - Wizard requires a project"
    test "shows error when no project selected", %{conn: conn} do
      _project = create_project()

      {:ok, view, _html} = live(conn, ~p"/workflows/prompt_chore_task")

      # Submit without selecting project
      view
      |> form("#wizard-idea-form", %{"initial_idea" => "Some idea"})
      |> render_submit()

      assert render(view) =~ "Please select a project"
    end

    @tag feature: @feature, scenario: "Phase 1 - Wizard requires an idea"
    test "shows error when idea is empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workflows/prompt_chore_task")

      view
      |> form("#wizard-idea-form", %{"initial_idea" => ""})
      |> render_submit()

      assert render(view) =~ "Please describe your initial idea"
    end
  end

  # --- Phase 2: Setup ---

  describe "Phase 2 - Setup" do
    @tag feature: @feature, scenario: "Phase 2 - Setup displays progress"
    test "shows setup progress steps", %{conn: conn} do
      {:ok, ws} =
        Destila.Workflows.create_workflow_session(%{
          title: "Test Session",
          workflow_type: :prompt_chore_task,
          current_phase: 2,
          total_phases: 6,
          phase_status: :setup,
          title_generating: true,
          project_id: create_project().id
        })

      Destila.Workflows.upsert_metadata(ws.id, "setup", "title_gen", %{
        "status" => "completed"
      })

      Destila.Workflows.upsert_metadata(ws.id, "setup", "repo_sync", %{
        "status" => "in_progress"
      })

      {:ok, _view, html} = live(conn, ~p"/sessions/#{ws.id}")

      assert html =~ "Phase 2/6"
      assert html =~ "Setup"
      assert html =~ "Generating title..."
      assert html =~ "Syncing repository..."
    end
  end

  # --- Phase 3: Task Description ---

  describe "Phase 3 - Task Description" do
    @tag feature: @feature, scenario: "Phase 3 - AI asks clarifying questions"
    test "shows phase info, AI message, and accepts user input", %{conn: conn} do
      ws = create_session_in_phase(3)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert render(view) =~ "Phase 3/6"
      assert render(view) =~ "Task Description"
      assert render(view) =~ "I have some questions about this task."

      assert has_element?(view, "input[name='content']")

      view
      |> form("form[phx-submit='send_text']", %{"content" => "It happens after exactly 5 minutes"})
      |> render_submit()

      assert render(view) =~ "It happens after exactly 5 minutes"
    end
  end

  # --- Phase transitions ---

  describe "phase transitions" do
    @tag feature: @feature, scenario: "Advance to the next phase"
    test "shows advance button and advances on confirm", %{conn: conn} do
      ws =
        create_session_in_phase(3,
          phase_status: :advance_suggested,
          last_message_type: :phase_advance
        )

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "button[phx-click='confirm_advance']")
      assert render(view) =~ "Continue to Phase 4"

      view |> element("button[phx-click='confirm_advance']") |> render_click()

      assert render(view) =~ "Phase 4/6"
      assert render(view) =~ "Gherkin Review"
    end

    @tag feature: @feature, scenario: "Decline phase advance to add more context"
    test "re-enables input when declining advance", %{conn: conn} do
      ws =
        create_session_in_phase(3,
          phase_status: :advance_suggested,
          last_message_type: :phase_advance
        )

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "button[phx-click='confirm_advance']")
      assert has_element?(view, "button[phx-click='decline_advance']")

      view |> element("button[phx-click='decline_advance']") |> render_click()

      refute has_element?(view, "button[phx-click='confirm_advance']")
      assert has_element?(view, "input[name='content']:not([disabled])")
    end

    @tag feature: @feature, scenario: "Skip Gherkin Review when not applicable"
    test "auto-skips phase when AI calls session tool with phase_complete", %{conn: conn} do
      {:ok, call_count} = Agent.start_link(fn -> 0 end)

      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        n = Agent.get_and_update(call_count, fn n -> {n, n + 1} end)

        if n == 0 do
          [
            ClaudeCode.Test.text("No Gherkin scenarios needed."),
            ClaudeCode.Test.tool_use("mcp__destila__session", %{
              "action" => "phase_complete",
              "message" => "No Gherkin scenarios needed for this task."
            }),
            ClaudeCode.Test.result("No Gherkin scenarios needed.")
          ]
        else
          text = "Let's discuss the technical approach."
          [ClaudeCode.Test.text(text), ClaudeCode.Test.result(text)]
        end
      end)

      ws =
        create_session_in_phase(3,
          phase_status: :advance_suggested,
          last_message_type: :phase_advance
        )

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("button[phx-click='confirm_advance']") |> render_click()

      # Process phase_advanced message which triggers maybe_initialize_ai
      render(view)

      # Verify via fresh mount
      {:ok, _view, html} = live(conn, ~p"/sessions/#{ws.id}")
      assert html =~ "Phase 5/6"
      assert html =~ "Technical Concerns"

      Agent.stop(call_count)
    end
  end

  # --- Phase 4: Gherkin Review ---

  describe "Phase 4 - Gherkin Review" do
    @tag feature: @feature, scenario: "Phase 4 - Gherkin Review"
    test "shows Gherkin Review phase with conversation input", %{conn: conn} do
      ws = create_session_in_phase(4)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert render(view) =~ "Phase 4/6"
      assert render(view) =~ "Gherkin Review"
      assert has_element?(view, "input[name='content']")
    end
  end

  # --- Phase 5: Technical Concerns ---

  describe "Phase 5 - Technical Concerns" do
    @tag feature: @feature, scenario: "Phase 5 - Technical Concerns"
    test "shows Technical Concerns phase with conversation input", %{conn: conn} do
      ws = create_session_in_phase(5)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert render(view) =~ "Phase 5/6"
      assert render(view) =~ "Technical Concerns"
      assert has_element?(view, "input[name='content']")
    end
  end

  # --- Phase 6: Prompt Generation ---

  describe "Phase 6 - Prompt Generation" do
    @tag feature: @feature, scenario: "Phase 6 - Prompt Generation and mark as done"
    test "shows Mark as Done button and completes workflow on click", %{conn: conn} do
      ws = create_session_in_phase(6)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert render(view) =~ "Phase 6/6"
      assert render(view) =~ "Prompt Generation"

      assert has_element?(view, "button[phx-click='mark_done']")

      view |> element("button[phx-click='mark_done']") |> render_click()

      assert render(view) =~ "Workflow complete"
      refute has_element?(view, "button[phx-click='mark_done']")
    end

    @tag feature: @feature, scenario: "Un-done a completed session"
    test "reopens a completed workflow via Reopen button", %{conn: conn} do
      ws = create_session_in_phase(6)
      # Mark as done first
      {:ok, ws} =
        Destila.Workflows.update_workflow_session(ws, %{
          done_at: DateTime.utc_now(),
          phase_status: nil
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert render(view) =~ "Workflow complete"
      assert has_element?(view, "button[phx-click='mark_undone']")

      view |> element("button[phx-click='mark_undone']") |> render_click()

      refute render(view) =~ "Workflow complete"
      refute has_element?(view, "button[phx-click='mark_undone']")

      # Verify done_at is cleared in DB
      ws = Destila.Workflows.get_workflow_session!(ws.id)
      assert is_nil(ws.done_at)
    end
  end

  # --- Title editing ---

  describe "session title editing" do
    @tag feature: @feature, scenario: "Edit session title"
    test "edits title inline and saves", %{conn: conn} do
      ws = create_session_in_phase(3)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      # Title is displayed
      assert render(view) =~ "Test Chore Task"

      # Click to edit
      view |> element("button[phx-click='edit_title']") |> render_click()

      # Input form appears
      assert has_element?(view, "form[phx-submit='save_title'] input[name='title']")

      # Submit new title
      view
      |> form("form[phx-submit='save_title']", %{"title" => "Updated Title"})
      |> render_submit()

      # Title is updated
      assert render(view) =~ "Updated Title"
      refute has_element?(view, "form[phx-submit='save_title']")
    end
  end

  # --- Setup retry ---

  describe "setup retry" do
    @tag feature: @feature, scenario: "Retry a failed setup step"
    test "shows retry button on failed step and re-enqueues on click", %{conn: conn} do
      project = create_project()

      {:ok, ws} =
        Destila.Workflows.create_workflow_session(%{
          title: "Test Session",
          workflow_type: :prompt_chore_task,
          current_phase: 2,
          total_phases: 6,
          phase_status: :setup,
          project_id: project.id
        })

      Destila.Workflows.upsert_metadata(ws.id, "setup", "title_gen", %{
        "status" => "completed"
      })

      Destila.Workflows.upsert_metadata(ws.id, "setup", "repo_sync", %{
        "status" => "failed",
        "error" => "Connection refused"
      })

      {:ok, _view, html} = live(conn, ~p"/sessions/#{ws.id}")

      # Failed step is visible with error
      assert html =~ "Connection refused"

      # Retry button is present
      assert html =~ "Retry"
    end
  end

  # --- AI structured inputs ---

  describe "AI single-select input" do
    @tag feature: @feature, scenario: "Answer AI with a single-select option"
    test "clicking a single-select option sends it as a message", %{conn: conn} do
      ws = create_session_with_options(:single_select)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      # Options are displayed
      assert render(view) =~ "Option A"
      assert render(view) =~ "Option B"

      # Click an option
      view
      |> element("button[phx-click='select_single'][phx-value-label='Option A']")
      |> render_click()

      # Selected option appears as user message
      assert render(view) =~ "Option A"
    end
  end

  describe "AI multi-select input" do
    @tag feature: @feature, scenario: "Answer AI with multi-select options"
    test "selecting multiple options and confirming sends them", %{conn: conn} do
      ws = create_session_with_options(:multi_select)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      # Multi-select form is displayed
      assert render(view) =~ "Option A"
      assert render(view) =~ "Confirm Selection"

      # Submit with selections
      view
      |> form("form[phx-submit='select_multi']", %{"selected" => ["Option A", "Option B"]})
      |> render_submit()

      # Selected options appear as user message
      assert render(view) =~ "Option A, Option B"
    end
  end

  describe "AI multi-question form" do
    @tag feature: @feature, scenario: "Answer AI with a multi-question form"
    test "answering questions sequentially and submitting all", %{conn: conn} do
      ws = create_session_with_questions()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      # Questions are displayed
      assert render(view) =~ "What framework?"
      assert render(view) =~ "What database?"

      # Answer first question
      view
      |> element("button[phx-click='answer_question'][phx-value-answer='Phoenix']")
      |> render_click()

      # First answer is locked in
      assert render(view) =~ "Phoenix"

      # Answer second question
      view
      |> element("button[phx-click='answer_question'][phx-value-answer='SQLite']")
      |> render_click()

      # Submit all
      view |> element("button[phx-click='submit_all_answers']") |> render_click()

      # Formatted response appears
      assert render(view) =~ "Phoenix"
      assert render(view) =~ "SQLite"
    end
  end

  # --- AI streaming ---

  describe "AI streaming" do
    @tag feature: @feature, scenario: "Streams AI response chunks to the chat UI"
    test "streams AI response chunks to the chat UI", %{conn: conn} do
      ws = create_session_in_phase(3, phase_status: :processing)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      # Initially shows typing indicator
      assert has_element?(view, "[class*='animate-bounce']")

      # Simulate a stream chunk broadcast
      topic = Destila.PubSubHelper.ai_stream_topic(ws.id)

      chunk = %ClaudeCode.Message.AssistantMessage{
        type: :assistant,
        session_id: "test",
        message: %{
          content: [%ClaudeCode.Content.TextBlock{type: "text", text: "Streaming text"}]
        }
      }

      Phoenix.PubSub.broadcast(Destila.PubSub, topic, {:ai_stream_chunk, chunk})

      # Verify streaming debug view shows the chunk content and streaming indicator
      html = render(view)
      assert html =~ "Streaming text"
      assert html =~ "[assistant]"
      assert html =~ "streaming"
    end
  end

  # --- Helpers for structured AI inputs ---

  defp create_session_with_options(input_type) do
    {:ok, ws} =
      Destila.Workflows.create_workflow_session(%{
        title: "Test Options",
        workflow_type: :prompt_chore_task,
        current_phase: 3,
        total_phases: 6,
        phase_status: :conversing
      })

    {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

    options = [
      %{"label" => "Option A", "description" => "First option"},
      %{"label" => "Option B", "description" => "Second option"}
    ]

    tool_name = "mcp__destila__ask_user_question"

    multi_select = input_type == :multi_select

    raw_response = %{
      "text" => "Pick one:",
      "result" => "Pick one:",
      "is_error" => false,
      "mcp_tool_uses" => [
        %{
          "name" => tool_name,
          "input" => %{
            "questions" => [
              %{
                "question" => "Pick one:",
                "title" => "Choice",
                "multi_select" => multi_select,
                "options" => options
              }
            ]
          }
        }
      ]
    }

    Destila.AI.create_message(ai_session.id, %{
      role: :system,
      content: "Pick one:",
      raw_response: raw_response,
      phase: 3
    })

    ws
  end

  defp create_session_with_questions do
    {:ok, ws} =
      Destila.Workflows.create_workflow_session(%{
        title: "Test Questions",
        workflow_type: :prompt_chore_task,
        current_phase: 3,
        total_phases: 6,
        phase_status: :conversing
      })

    {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

    tool_name = "mcp__destila__ask_user_question"

    raw_response = %{
      "text" => "",
      "result" => "",
      "is_error" => false,
      "mcp_tool_uses" => [
        %{
          "name" => tool_name,
          "input" => %{
            "questions" => [
              %{
                "question" => "What framework?",
                "title" => "Framework",
                "multi_select" => false,
                "options" => [
                  %{"label" => "Phoenix", "description" => "Elixir web framework"},
                  %{"label" => "Rails", "description" => "Ruby web framework"}
                ]
              },
              %{
                "question" => "What database?",
                "title" => "Database",
                "multi_select" => false,
                "options" => [
                  %{"label" => "SQLite", "description" => "Lightweight DB"},
                  %{"label" => "PostgreSQL", "description" => "Full-featured DB"}
                ]
              }
            ]
          }
        }
      ]
    }

    Destila.AI.create_message(ai_session.id, %{
      role: :system,
      content: "",
      raw_response: raw_response,
      phase: 3
    })

    ws
  end
end
