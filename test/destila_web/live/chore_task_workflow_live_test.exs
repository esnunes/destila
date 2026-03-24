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

  # Creates a chore_task prompt in the given phase with appropriate state.
  # Last message is always from system to avoid auto-triggering AI on mount.
  defp create_prompt_in_phase(phase, opts \\ []) do
    phase_status = Keyword.get(opts, :phase_status, :conversing)
    column = Keyword.get(opts, :column, :request)

    # For advance_suggested tests, the last message needs to contain the marker
    last_content =
      if Keyword.get(opts, :last_message_type) == :phase_advance,
        do: "I have some questions about this task. <<READY_TO_ADVANCE>>",
        else: "I have some questions about this task."

    {:ok, prompt} =
      Destila.Prompts.create_prompt(%{
        title: "Test Chore Task",
        workflow_type: :chore_task,
        project_id: nil,
        column: column,
        steps_completed: phase,
        steps_total: 4,
        phase_status: phase_status
      })

    # Initial conversation: system question + user answer
    {:ok, _} =
      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: "Let's work on your task.",
        phase: 1
      })

    {:ok, _} =
      Destila.Messages.create_message(prompt.id, %{
        role: :user,
        content: "Fix the login timeout bug",
        phase: 1
      })

    # Last message from system (prevents ensure_ai_session from auto-triggering)
    # For AI messages, store raw_response so Messages.process derives message_type
    raw_response =
      if Keyword.get(opts, :last_message_type) != nil,
        do: %{
          "text" => last_content,
          "result" => last_content,
          "mcp_tool_uses" => [],
          "is_error" => false
        },
        else: nil

    {:ok, _} =
      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: last_content,
        raw_response: raw_response,
        phase: phase
      })

    prompt
  end

  describe "Phase 1 - Task Description" do
    @tag feature: @feature, scenario: "Phase 1 - AI asks clarifying questions"
    test "shows phase info, AI message, and accepts user input", %{conn: conn} do
      prompt = create_prompt_in_phase(1)
      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      # Header shows Phase 1
      assert render(view) =~ "Phase 1/4"
      assert render(view) =~ "Task Description"

      # AI's question is visible
      assert render(view) =~ "I have some questions about this task."

      # User can send a response
      assert has_element?(view, "input[name='content']")

      view
      |> form("form[phx-submit='send_text']", %{"content" => "It happens after exactly 5 minutes"})
      |> render_submit()

      # User message appears in chat
      assert render(view) =~ "It happens after exactly 5 minutes"
    end
  end

  describe "phase transitions" do
    @tag feature: @feature, scenario: "Advance to the next phase"
    test "shows advance button and advances on confirm", %{conn: conn} do
      prompt =
        create_prompt_in_phase(1,
          phase_status: :advance_suggested,
          last_message_type: :phase_advance
        )

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      # Advance button is shown
      assert has_element?(view, "button[phx-click='confirm_advance']")
      assert render(view) =~ "Continue to Phase 2"

      # Click advance
      view |> element("button[phx-click='confirm_advance']") |> render_click()

      # Header updates to Phase 2
      assert render(view) =~ "Phase 2/4"

      # Phase divider appears with phase name
      assert render(view) =~ "Gherkin Review"
    end

    @tag feature: @feature, scenario: "Decline phase advance to add more context"
    test "re-enables input when declining advance", %{conn: conn} do
      prompt =
        create_prompt_in_phase(1,
          phase_status: :advance_suggested,
          last_message_type: :phase_advance
        )

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      # Both buttons shown
      assert has_element?(view, "button[phx-click='confirm_advance']")
      assert has_element?(view, "button[phx-click='decline_advance']")

      # Click decline
      view |> element("button[phx-click='decline_advance']") |> render_click()

      # Advance buttons gone
      refute has_element?(view, "button[phx-click='confirm_advance']")

      # Text input is available and not disabled
      assert has_element?(view, "input[name='content']:not([disabled])")
    end

    @tag feature: @feature, scenario: "Skip Gherkin Review when not applicable"
    test "auto-skips phase when AI returns SKIP_PHASE", %{conn: conn} do
      # First AI call returns SKIP_PHASE (phase 2), second returns normal (phase 3)
      {:ok, call_count} = Agent.start_link(fn -> 0 end)

      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        n = Agent.get_and_update(call_count, fn n -> {n, n + 1} end)

        text =
          if n == 0,
            do: "No Gherkin scenarios needed for this task. <<SKIP_PHASE>>",
            else: "Let's discuss the technical approach."

        [ClaudeCode.Test.text(text), ClaudeCode.Test.result(text)]
      end)

      prompt =
        create_prompt_in_phase(1,
          phase_status: :advance_suggested,
          last_message_type: :phase_advance
        )

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      # Advance to Phase 2 (Gherkin Review) — AI will return SKIP_PHASE,
      # which triggers handle_skip_phase to auto-advance to Phase 3
      view |> element("button[phx-click='confirm_advance']") |> render_click()

      # Wait for async skip to complete
      assert_async(view, &(&1 =~ "Phase 3/4"))

      html = render(view)
      assert html =~ "Technical Concerns"

      Agent.stop(call_count)
    end
  end

  describe "Phase 2 - Gherkin Review" do
    @tag feature: @feature, scenario: "Phase 2 - Gherkin Review"
    test "shows Gherkin Review phase with conversation input", %{conn: conn} do
      prompt = create_prompt_in_phase(2)
      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      assert render(view) =~ "Phase 2/4"
      assert render(view) =~ "Gherkin Review"
      assert has_element?(view, "input[name='content']")
    end
  end

  describe "Phase 3 - Technical Concerns" do
    @tag feature: @feature, scenario: "Phase 3 - Technical Concerns"
    test "shows Technical Concerns phase with conversation input", %{conn: conn} do
      prompt = create_prompt_in_phase(3)
      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      assert render(view) =~ "Phase 3/4"
      assert render(view) =~ "Technical Concerns"
      assert has_element?(view, "input[name='content']")
    end
  end

  describe "Phase 4 - Prompt Generation" do
    @tag feature: @feature, scenario: "Phase 4 - Prompt Generation and mark as done"
    test "shows Mark as Done button and completes workflow on click", %{conn: conn} do
      prompt = create_prompt_in_phase(4)
      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      assert render(view) =~ "Phase 4/4"
      assert render(view) =~ "Prompt Generation"

      # Mark as Done button is available
      assert has_element?(view, "button[phx-click='mark_done']")

      # Click Mark as Done
      view |> element("button[phx-click='mark_done']") |> render_click()

      # Workflow is complete
      assert render(view) =~ "Workflow complete"

      # Mark as Done button disappears
      refute has_element?(view, "button[phx-click='mark_done']")
    end
  end

  # Retries render(view) until the assertion passes or timeout is reached.
  # Needed for tests that depend on async PubSub updates from spawned Tasks.
  defp assert_async(view, assertion, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_async(view, assertion, deadline)
  end

  defp do_assert_async(view, assertion, deadline) do
    if assertion.(render(view)) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("Async assertion not met within timeout")
      else
        :timer.sleep(50)
        do_assert_async(view, assertion, deadline)
      end
    end
  end
end
