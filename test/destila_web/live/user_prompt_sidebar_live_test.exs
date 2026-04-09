defmodule DestilaWeb.UserPromptSidebarLiveTest do
  @moduledoc """
  LiveView tests for User Prompt in Sidebar.
  Feature: features/exported_metadata.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @sample_user_prompt """
  Fix the login timeout bug by increasing the session TTL from 30 to 60 minutes.

  ## Steps

  1. Update `config/runtime.exs`
  2. Change `session_ttl` from 30 to 60 minutes
  3. Add a test for the new timeout value
  """

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

  defp create_session(attrs) do
    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(
        Map.merge(
          %{
            title: "Test Session",
            workflow_type: :brainstorm_idea,
            project_id: nil,
            done_at: DateTime.utc_now(),
            current_phase: 4,
            total_phases: 4
          },
          attrs
        )
      )

    ws
  end

  describe "user prompt sidebar section" do
    @tag feature: "exported_metadata", scenario: "User prompt appears at the top of the sidebar"
    test "shows user prompt section with view button when prompt exists", %{conn: conn} do
      ws = create_session(%{user_prompt: @sample_user_prompt})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#user-prompt-section")
      assert has_element?(view, "#view-user-prompt-btn")
    end
  end

  describe "user prompt modal" do
    @tag feature: "exported_metadata", scenario: "Open user prompt in markdown modal"
    test "clicking view button opens modal with markdown viewer", %{conn: conn} do
      ws = create_session(%{user_prompt: @sample_user_prompt})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("#view-user-prompt-btn") |> render_click()

      assert has_element?(view, "#user-prompt-modal")
      assert has_element?(view, "#user-prompt-modal-viewer")
      assert has_element?(view, "#user-prompt-modal-viewer [role='tablist']")
      assert has_element?(view, "#user-prompt-modal-viewer button[data-view='rendered']")
      assert has_element?(view, "#user-prompt-modal-viewer button[data-view='markdown']")
      assert has_element?(view, "#user-prompt-modal-viewer [data-rendered]")
      assert has_element?(view, "#user-prompt-modal-viewer [data-markdown]")
    end

    @tag feature: "exported_metadata", scenario: "Open user prompt in markdown modal"
    test "clicking close button dismisses the modal", %{conn: conn} do
      ws = create_session(%{user_prompt: @sample_user_prompt})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("#view-user-prompt-btn") |> render_click()
      assert has_element?(view, "#user-prompt-modal")

      view
      |> element("#user-prompt-modal button[phx-click='close_user_prompt_modal']")
      |> render_click()

      refute has_element?(view, "#user-prompt-modal")
    end
  end
end
