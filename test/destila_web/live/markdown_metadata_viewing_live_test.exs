defmodule DestilaWeb.MarkdownMetadataViewingLiveTest do
  @moduledoc """
  LiveView tests for Markdown Metadata Viewing.
  Feature: features/markdown_metadata_viewing.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "markdown_metadata_viewing"

  @sample_markdown """
  # Implementation Prompt

  ## Overview

  Fix the login timeout bug by increasing the session TTL.

  ## Steps

  1. Update `config/runtime.exs`
  2. Change `session_ttl` from 30 to 60 minutes
  3. Add a test for the new timeout value

  ```elixir
  config :my_app, session_ttl: :timer.minutes(60)
  ```
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

  defp create_session_with_markdown_export do
    {:ok, workflow_session} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test Session",
        workflow_type: :brainstorm_idea,
        project_id: nil,
        done_at: DateTime.utc_now(),
        current_phase: 4,
        total_phases: 4
      })

    {:ok, ai_session} = Destila.AI.get_or_create_ai_session(workflow_session.id)

    {:ok, _} =
      Destila.AI.create_message(ai_session.id, %{
        role: :system,
        content: "Here is your implementation prompt.",
        raw_response: %{
          "text" => "Here is your implementation prompt.",
          "result" => "Here is your implementation prompt.",
          "mcp_tool_uses" => [
            %{
              "name" => "mcp__destila__session",
              "input" => %{
                "action" => "export",
                "key" => "generated_prompt",
                "value" => @sample_markdown,
                "type" => "markdown"
              }
            }
          ],
          "is_error" => false
        },
        phase: 4,
        workflow_session_id: workflow_session.id
      })

    {:ok, _} =
      Destila.Workflows.upsert_metadata(
        workflow_session.id,
        "phase_4",
        "generated_prompt",
        %{"markdown" => @sample_markdown},
        exported: true
      )

    workflow_session
  end

  describe "default rendered view" do
    @tag feature: @feature, scenario: "Default to rendered HTML view"
    test "renders the markdown card with toggle buttons and copy button", %{conn: conn} do
      ws = create_session_with_markdown_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      # Card exists with export-md ID prefix and data-content
      assert has_element?(view, "[id^='export-md-']")
      assert has_element?(view, "[data-content]")

      # Toggle buttons present with tablist
      assert has_element?(view, "[role='tablist']")
      assert has_element?(view, "button[data-view='rendered']")
      assert has_element?(view, "button[data-view='markdown']")

      # Copy button present
      assert has_element?(view, "button.md-card-copy-btn")

      # Both view containers present
      assert has_element?(view, "[data-rendered]")
      assert has_element?(view, "[data-markdown]")

      # Rendered view has prose wrapper
      assert has_element?(view, "[data-rendered].prose")

      # Markdown view has pre/code block
      assert has_element?(view, "[data-markdown] pre code")

      # Card header shows humanized key
      html = render(view)
      assert html =~ "Generated Prompt"
    end
  end

  describe "markdown view structure" do
    @tag feature: @feature, scenario: "Toggle to markdown view"
    test "markdown view contains raw markdown in pre/code block", %{conn: conn} do
      ws = create_session_with_markdown_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      code_html = view |> element("[data-markdown] pre code") |> render()
      assert code_html =~ "# Implementation Prompt"
      assert code_html =~ "## Overview"
      assert code_html =~ "```elixir"
    end
  end

  describe "rendered view structure" do
    @tag feature: @feature, scenario: "Toggle back to rendered view"
    test "rendered view contains HTML-rendered markdown", %{conn: conn} do
      ws = create_session_with_markdown_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "[data-rendered] h1")
      assert has_element?(view, "[data-rendered] h2")
    end
  end

  describe "copy button" do
    @tag feature: @feature, scenario: "Copy markdown to clipboard"
    test "copy button has correct aria-label and icon", %{conn: conn} do
      ws = create_session_with_markdown_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "button[aria-label='Copy markdown to clipboard']")
      assert has_element?(view, "button.md-card-copy-btn .hero-clipboard-document-micro")
    end

    @tag feature: @feature, scenario: "Copy works from either view"
    test "data-content attribute contains the raw markdown for JS hook", %{conn: conn} do
      ws = create_session_with_markdown_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      card_html = view |> element("[id^='export-md-']") |> render()
      assert card_html =~ "data-content=\""
      assert card_html =~ "# Implementation Prompt"
    end
  end

  describe "sidebar entry" do
    @tag feature: "exported_metadata", scenario: "Markdown metadata sidebar entry has view button"
    test "markdown entry shows view button instead of details block", %{conn: conn} do
      ws = create_session_with_markdown_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      # Should have a view button, not a details/summary
      assert has_element?(view, "button[phx-click='open_markdown_modal']")
      refute has_element?(view, "details[id^='metadata-entry-']")

      # Should show document icon
      assert has_element?(view, "[id^='metadata-entry-'] .hero-document-text-micro")
    end
  end

  describe "markdown modal" do
    @tag feature: @feature, scenario: "Open markdown in modal from sidebar"
    test "clicking sidebar view button opens markdown modal", %{conn: conn} do
      ws = create_session_with_markdown_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("button[phx-click='open_markdown_modal']") |> render_click()

      assert has_element?(view, "#markdown-modal")
      assert has_element?(view, "#markdown-modal-viewer")
      # Modal has tabs and copy button
      assert has_element?(view, "#markdown-modal-viewer [role='tablist']")
      assert has_element?(view, "#markdown-modal-viewer button[data-view='rendered']")
      assert has_element?(view, "#markdown-modal-viewer button[data-view='markdown']")
      assert has_element?(view, "#markdown-modal-viewer .md-card-copy-btn")
      # Modal has rendered and raw views
      assert has_element?(view, "#markdown-modal-viewer [data-rendered]")
      assert has_element?(view, "#markdown-modal-viewer [data-markdown]")
    end

    @tag feature: @feature, scenario: "Open markdown in modal from sidebar"
    test "modal shows humanized key in header", %{conn: conn} do
      ws = create_session_with_markdown_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("button[phx-click='open_markdown_modal']") |> render_click()

      modal_html = view |> element("#markdown-modal") |> render()
      assert modal_html =~ "Generated Prompt"
    end

    @tag feature: @feature, scenario: "Close markdown modal"
    test "clicking close button dismisses the modal", %{conn: conn} do
      ws = create_session_with_markdown_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("button[phx-click='open_markdown_modal']") |> render_click()
      assert has_element?(view, "#markdown-modal")

      view
      |> element("#markdown-modal button[phx-click='close_markdown_modal']")
      |> render_click()

      refute has_element?(view, "#markdown-modal")
    end

    @tag feature: @feature, scenario: "Close markdown modal"
    test "inline markdown card remains after closing modal", %{conn: conn} do
      ws = create_session_with_markdown_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("button[phx-click='open_markdown_modal']") |> render_click()

      view
      |> element("#markdown-modal button[phx-click='close_markdown_modal']")
      |> render_click()

      # Inline card still present
      assert has_element?(view, "[id^='export-md-']")
    end
  end
end
