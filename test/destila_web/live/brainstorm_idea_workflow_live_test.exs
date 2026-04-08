defmodule DestilaWeb.BrainstormIdeaWorkflowLiveTest do
  @moduledoc """
  LiveView tests for the Brainstorm Idea AI-Driven Workflow.
  Feature: features/brainstorm_idea_workflow.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Destila.Executions

  @feature "brainstorm_idea_workflow"

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

  # Creates a brainstorm_idea session in the given phase with appropriate state.
  defp create_session_in_phase(phase, opts \\ []) do
    pe_status = Keyword.get(opts, :pe_status, :awaiting_input)
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

        :phase_complete ->
          {"Moving to the next phase.",
           [
             %{
               "name" => "mcp__destila__session",
               "input" => %{
                 "action" => "phase_complete",
                 "message" => "Moving to the next phase."
               }
             }
           ]}

        _ ->
          {"I have some questions about this task.", []}
      end

    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test Brainstorm Idea",
        workflow_type: :brainstorm_idea,
        project_id: nil,
        current_phase: phase,
        total_phases: 4
      })

    # Create PE to derive the phase status
    {:ok, _pe} = Executions.create_phase_execution(ws, phase, %{status: pe_status})

    {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

    {:ok, _} =
      Destila.AI.create_message(ai_session.id, %{
        role: :system,
        content: "Let's work on your task.",
        phase: 1,
        workflow_session_id: ws.id
      })

    {:ok, _} =
      Destila.AI.create_message(ai_session.id, %{
        role: :user,
        content: "Fix the login timeout bug",
        phase: 1,
        workflow_session_id: ws.id
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
        phase: phase,
        workflow_session_id: ws.id
      })

    ws
  end

  # --- Creation form ---

  describe "Creation form" do
    @tag feature: @feature, scenario: "Creation form collects project and idea"
    test "collects project and idea, creates session, redirects", %{conn: conn} do
      project = create_project()

      {:ok, view, _html} = live(conn, ~p"/workflows/brainstorm_idea")

      # Shows creation form
      assert has_element?(view, "#project-list")
      assert has_element?(view, "#input_text")

      # Select project and enter idea
      view |> element("#project-#{project.id}") |> render_click()
      assert render(view) =~ "border-primary"

      view
      |> form("#manual-input-form", %{"input_text" => "Fix the login timeout bug"})
      |> render_submit()

      # Redirects to session detail page
      {path, _flash} = assert_redirect(view)
      assert path =~ "/sessions/"
    end

    @tag feature: @feature, scenario: "Creation form requires a project"
    test "shows error when no project selected", %{conn: conn} do
      _project = create_project()

      {:ok, view, _html} = live(conn, ~p"/workflows/brainstorm_idea")

      # Enter idea via change event then click start button
      view
      |> form("#manual-input-form", %{"input_text" => "Some idea"})
      |> render_change()

      view |> element("#start-workflow-btn") |> render_click()

      assert render(view) =~ "Please select a project"
    end

    @tag feature: @feature, scenario: "Creation form requires an idea"
    test "shows error when idea is empty", %{conn: conn} do
      project = create_project()
      {:ok, view, _html} = live(conn, ~p"/workflows/brainstorm_idea")

      view |> element("#project-#{project.id}") |> render_click()
      view |> element("#start-workflow-btn") |> render_click()

      assert render(view) =~ "Please select or write an idea"
    end
  end

  # --- Setup ---

  describe "Setup" do
    @tag feature: @feature, scenario: "Setup displays progress"
    test "shows setup progress", %{conn: conn} do
      {:ok, ws} =
        Destila.Workflows.insert_workflow_session(%{
          title: "Test Session",
          workflow_type: :brainstorm_idea,
          current_phase: 1,
          total_phases: 4,
          title_generating: true,
          project_id: create_project().id
        })

      # No PE created — derived status is :setup

      {:ok, _view, html} = live(conn, ~p"/sessions/#{ws.id}")

      assert html =~ "Phase 1/4"
      assert html =~ "Task Description"
      assert html =~ "Preparing workspace..."
    end
  end

  # --- Phase 1: Task Description ---

  describe "Phase 1 - Task Description" do
    @tag feature: @feature, scenario: "Phase 1 - AI asks clarifying questions"
    test "shows phase info, AI message, and accepts user input", %{conn: conn} do
      ws = create_session_in_phase(1)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert render(view) =~ "Phase 1/4"
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
        create_session_in_phase(1,
          pe_status: :awaiting_confirmation,
          last_message_type: :phase_advance
        )

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "button[phx-click='confirm_advance']")
      assert render(view) =~ "Continue to Phase 2"

      view |> element("button[phx-click='confirm_advance']") |> render_click()

      assert render(view) =~ "Phase 2/4"
      assert render(view) =~ "Gherkin Review"
    end

    @tag feature: @feature, scenario: "Decline phase advance to add more context"
    test "re-enables input when declining advance", %{conn: conn} do
      ws =
        create_session_in_phase(1,
          pe_status: :awaiting_confirmation,
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
        create_session_in_phase(1,
          pe_status: :awaiting_confirmation,
          last_message_type: :phase_advance
        )

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("button[phx-click='confirm_advance']") |> render_click()

      # Process phase_advanced message which triggers maybe_initialize_ai
      render(view)

      # Verify via fresh mount
      {:ok, _view, html} = live(conn, ~p"/sessions/#{ws.id}")
      assert html =~ "Phase 3/4"
      assert html =~ "Technical Concerns"

      Agent.stop(call_count)
    end
  end

  # --- Phase 2: Gherkin Review ---

  describe "Phase 2 - Gherkin Review" do
    @tag feature: @feature, scenario: "Phase 2 - Gherkin Review"
    test "shows Gherkin Review phase with conversation input", %{conn: conn} do
      ws = create_session_in_phase(2)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert render(view) =~ "Phase 2/4"
      assert render(view) =~ "Gherkin Review"
      assert has_element?(view, "input[name='content']")
    end
  end

  # --- Phase 3: Technical Concerns ---

  describe "Phase 3 - Technical Concerns" do
    @tag feature: @feature, scenario: "Phase 3 - Technical Concerns"
    test "shows Technical Concerns phase with conversation input", %{conn: conn} do
      ws = create_session_in_phase(3)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert render(view) =~ "Phase 3/4"
      assert render(view) =~ "Technical Concerns"
      assert has_element?(view, "input[name='content']")
    end
  end

  # --- Phase 4: Prompt Generation ---

  describe "Phase 4 - Prompt Generation" do
    @tag feature: @feature, scenario: "Phase 4 - Prompt Generation and mark as done"
    test "shows Mark as Done button and completes workflow on click", %{conn: conn} do
      ws = create_session_in_phase(4)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert render(view) =~ "Phase 4/4"
      assert render(view) =~ "Prompt Generation"

      assert has_element?(view, "button[phx-click='mark_done']")

      view |> element("button[phx-click='mark_done']") |> render_click()

      assert render(view) =~ "Workflow complete"
      refute has_element?(view, "button[phx-click='mark_done']")
    end

    @tag feature: @feature, scenario: "Mark as Done is disabled while last phase is processing"
    test "disables Mark as Done while the last phase is still processing", %{conn: conn} do
      ws = create_session_in_phase(4, pe_status: :processing)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert render(view) =~ "Phase 4/4"
      assert has_element?(view, "#mark-done-btn[disabled]")
    end

    @tag feature: @feature, scenario: "Un-done a completed session"
    test "reopens a completed workflow via Reopen button", %{conn: conn} do
      ws = create_session_in_phase(4)
      # Mark as done first
      {:ok, ws} =
        Destila.Workflows.update_workflow_session(ws, %{done_at: DateTime.utc_now()})

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
      ws = create_session_in_phase(1)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      # Title is displayed
      assert render(view) =~ "Test Brainstorm Idea"

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

  # Setup retry removed — per-step failure tracking no longer exists.
  # If the Oban worker fails, it retries automatically (max 3 attempts).

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
      ws = create_session_in_phase(1, pe_status: :processing)
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

      # Verify streaming debug view shows the chunk content
      html = render(view)
      assert html =~ "Streaming text"
      assert html =~ "[assistant]"
    end
  end

  # --- Phase toggle preservation ---

  describe "phase toggle preservation" do
    @tag feature: @feature, scenario: "Manually expanded previous phase stays open during updates"
    test "phase sections have PhaseToggle hook wired with correct IDs", %{conn: conn} do
      ws = create_session_in_phase(3)
      {:ok, view, _html} = live(conn, "/sessions/#{ws.id}")

      # Phase 1 (< 3) should be collapsed by default, with the hook attached
      assert has_element?(view, "details#phase-section-1[phx-hook*='PhaseToggle']")
      refute has_element?(view, "details#phase-section-1[open]")

      # Phase 3 (== current) should be open by default, with the hook attached
      assert has_element?(view, "details#phase-section-3[phx-hook*='PhaseToggle']")
      assert has_element?(view, "details#phase-section-3[open]")
    end

    @tag feature: @feature,
         scenario: "Manually collapsed current phase stays closed during updates"
    test "server re-render preserves default open states without JS hook", %{conn: conn} do
      ws = create_session_in_phase(3)
      {:ok, view, _html} = live(conn, "/sessions/#{ws.id}")

      # Verify initial defaults
      assert has_element?(view, "details#phase-section-3[open]")
      refute has_element?(view, "details#phase-section-1[open]")

      # Simulate a PubSub-driven re-render (e.g., metadata update)
      send(view.pid, {:metadata_updated, ws.id})

      # Server should recompute the same open states
      assert has_element?(view, "details#phase-section-3[open]")
      refute has_element?(view, "details#phase-section-1[open]")
    end
  end

  # --- Helpers for structured AI inputs ---

  defp create_session_with_options(input_type) do
    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test Options",
        workflow_type: :brainstorm_idea,
        current_phase: 1,
        total_phases: 4
      })

    {:ok, _pe} = Executions.create_phase_execution(ws, 1, %{status: :awaiting_input})

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
      phase: 1,
      workflow_session_id: ws.id
    })

    ws
  end

  defp create_session_with_questions do
    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test Questions",
        workflow_type: :brainstorm_idea,
        current_phase: 1,
        total_phases: 4
      })

    {:ok, _pe} = Executions.create_phase_execution(ws, 1, %{status: :awaiting_input})

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
      phase: 1,
      workflow_session_id: ws.id
    })

    ws
  end

  # --- Exported Metadata Sidebar ---

  describe "exported metadata sidebar" do
    @tag feature: "exported_metadata",
         scenario: "Sidebar displays exported metadata during workflow execution"
    test "shows sidebar with exported metadata entries", %{conn: conn} do
      ws = create_session_in_phase(1)

      Destila.Workflows.upsert_metadata(
        ws.id,
        "Prompt Generation",
        "prompt_generated",
        %{"text" => "Do the thing"},
        exported: true
      )

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#metadata-sidebar")
      assert has_element?(view, "#metadata-sidebar-content")
      assert render(view) =~ "Prompt generated"
    end

    @tag feature: "exported_metadata",
         scenario: "Sidebar is empty when no metadata is exported"
    test "shows empty state when no metadata is exported", %{conn: conn} do
      ws = create_session_in_phase(1)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#metadata-sidebar")
      assert render(view) =~ "No metadata exported yet"
    end

    @tag feature: "exported_metadata",
         scenario: "Sidebar updates in real-time as metadata is exported"
    test "updates sidebar when new exported metadata arrives via PubSub", %{conn: conn} do
      ws = create_session_in_phase(1)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert render(view) =~ "No metadata exported yet"

      Destila.Workflows.upsert_metadata(
        ws.id,
        "Prompt Generation",
        "prompt_generated",
        %{"text" => "New prompt"},
        exported: true
      )

      # Wait for PubSub update to propagate
      _ = render(view)

      refute render(view) =~ "No metadata exported yet"
      assert render(view) =~ "Prompt generated"
    end

    @tag feature: "exported_metadata", scenario: "Sidebar is open by default"
    test "sidebar is visible by default", %{conn: conn} do
      ws = create_session_in_phase(1)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#metadata-sidebar")
      assert has_element?(view, "#metadata-sidebar-content")
    end
  end

  # --- Aliveness Indicator ---

  describe "aliveness indicator" do
    @tag feature: @feature,
         scenario: "Workflow runner shows gray indicator when GenServer is not expected"
    test "shows gray dot when GenServer is not running and not expected", %{conn: conn} do
      ws = create_session_in_phase(1, pe_status: :awaiting_input)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "span[title='AI session idle']")
    end

    @tag feature: @feature,
         scenario:
           "Workflow runner shows red indicator when GenServer is unexpectedly not running"
    test "shows red dot when GenServer should be running but is not", %{conn: conn} do
      ws = create_session_in_phase(1, pe_status: :processing)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "span[title='AI session not running (unexpected)']")
    end

    @tag feature: @feature,
         scenario: "Workflow runner shows green indicator when Claude Code GenServer is running"
    test "shows green dot when GenServer is running", %{conn: conn} do
      ws = create_session_in_phase(1, pe_status: :processing)

      {:ok, _pid} =
        Agent.start_link(fn -> nil end,
          name: {:via, Registry, {Destila.AI.SessionRegistry, ws.id}}
        )

      # Notify the tracker so it monitors the agent and updates ETS
      Phoenix.PubSub.broadcast(
        Destila.PubSub,
        Destila.PubSubHelper.claude_session_topic(),
        {:claude_session_started, ws.id}
      )

      _ = :sys.get_state(Destila.AI.AlivenessTracker)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "span[title='AI session running']")
    end

    @tag feature: @feature,
         scenario: "Workflow runner indicator updates in real-time when GenServer stops"
    test "updates from green to red when GenServer stops", %{conn: conn} do
      ws = create_session_in_phase(1, pe_status: :processing)

      {:ok, pid} =
        Agent.start_link(fn -> nil end,
          name: {:via, Registry, {Destila.AI.SessionRegistry, ws.id}}
        )

      # Notify the tracker so it monitors the agent and updates ETS
      Phoenix.PubSub.broadcast(
        Destila.PubSub,
        Destila.PubSubHelper.claude_session_topic(),
        {:claude_session_started, ws.id}
      )

      _ = :sys.get_state(Destila.AI.AlivenessTracker)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "span[title='AI session running']")

      # Stop the agent — tracker receives :DOWN, broadcasts {:aliveness_changed, ws.id, false}
      Agent.stop(pid)
      _ = render(view)

      assert has_element?(view, "span[title='AI session not running (unexpected)']")
    end
  end
end
