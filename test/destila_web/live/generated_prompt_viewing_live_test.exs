defmodule DestilaWeb.GeneratedPromptViewingLiveTest do
  @moduledoc """
  LiveView tests for Generated Prompt Viewing.
  Feature: features/generated_prompt_viewing.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "generated_prompt_viewing"

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

  defp create_prompt_with_generated_prompt do
    {:ok, session} = Destila.AI.Session.start_link(timeout_ms: :timer.minutes(5))

    prompt =
      Destila.Store.create_prompt(%{
        title: "Test Prompt",
        workflow_type: :chore_task,
        project_id: nil,
        board: :crafting,
        column: :done,
        steps_completed: 4,
        steps_total: 4,
        phase_status: nil,
        ai_session: session
      })

    Destila.Store.add_message(prompt.id, %{
      role: :system,
      content: @sample_markdown,
      input_type: :text,
      step: 4,
      message_type: :generated_prompt
    })

    Destila.Store.get_prompt(prompt.id)
  end

  describe "default rendered view" do
    @tag feature: @feature, scenario: "Default to rendered HTML view"
    test "renders the prompt card with toggle buttons and copy button", %{conn: conn} do
      prompt = create_prompt_with_generated_prompt()
      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      # Card exists with ID and data-content
      assert has_element?(view, "[id^='prompt-card-']")
      assert has_element?(view, "[data-content]")

      # Toggle buttons present with tablist
      assert has_element?(view, "[role='tablist']")
      assert has_element?(view, "button[data-view='rendered']")
      assert has_element?(view, "button[data-view='markdown']")

      # Copy button present
      assert has_element?(view, "button.prompt-copy-btn")

      # Both view containers present
      assert has_element?(view, "[data-rendered]")
      assert has_element?(view, "[data-markdown]")

      # Rendered view has prose wrapper
      assert has_element?(view, "[data-rendered].prose")

      # Markdown view has pre/code block
      assert has_element?(view, "[data-markdown] pre code")
    end
  end

  describe "markdown view structure" do
    @tag feature: @feature, scenario: "Toggle to markdown view"
    test "markdown view contains raw markdown in pre/code block", %{conn: conn} do
      prompt = create_prompt_with_generated_prompt()
      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      # Use render(element) to get the code block content
      code_html = view |> element("[data-markdown] pre code") |> render()
      assert code_html =~ "# Implementation Prompt"
      assert code_html =~ "## Overview"
      assert code_html =~ "```elixir"
    end
  end

  describe "rendered view structure" do
    @tag feature: @feature, scenario: "Toggle back to rendered view"
    test "rendered view contains HTML-rendered markdown", %{conn: conn} do
      prompt = create_prompt_with_generated_prompt()
      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      # Rendered view should contain HTML elements from Earmark conversion
      assert has_element?(view, "[data-rendered] h1")
      assert has_element?(view, "[data-rendered] h2")
    end
  end

  describe "copy button" do
    @tag feature: @feature, scenario: "Copy markdown to clipboard"
    test "copy button has correct aria-label and icon", %{conn: conn} do
      prompt = create_prompt_with_generated_prompt()
      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      assert has_element?(view, "button[aria-label='Copy markdown to clipboard']")
      assert has_element?(view, "button.prompt-copy-btn .hero-clipboard-document-micro")
    end

    @tag feature: @feature, scenario: "Copy works from either view"
    test "data-content attribute contains the raw markdown for JS hook", %{conn: conn} do
      prompt = create_prompt_with_generated_prompt()
      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}")

      # The card's data-content holds the raw markdown for the JS hook to copy
      card_html = view |> element("[id^='prompt-card-']") |> render()
      assert card_html =~ "data-content=\""
      assert card_html =~ "# Implementation Prompt"
    end
  end
end
