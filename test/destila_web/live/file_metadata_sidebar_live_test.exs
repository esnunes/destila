defmodule DestilaWeb.FileMetadataSidebarLiveTest do
  @moduledoc """
  LiveView tests for text_file and markdown_file sidebar modals.
  Feature: features/exported_metadata.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    ClaudeCode.Test.set_mode_to_shared()

    ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
      [
        ClaudeCode.Test.text("AI response"),
        ClaudeCode.Test.result("AI response")
      ]
    end)

    {:ok, conn: conn}
  end

  defp create_session_with_text_file_export do
    path = Path.join(System.tmp_dir!(), "destila_test_#{System.unique_integer([:positive])}.txt")
    File.write!(path, "Hello from text file\nLine two")
    on_exit(fn -> File.rm(path) end)

    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test Session",
        workflow_type: :brainstorm_idea,
        project_id: nil,
        done_at: DateTime.utc_now(),
        current_phase: 4,
        total_phases: 4
      })

    {:ok, _} =
      Destila.Workflows.upsert_metadata(
        ws.id,
        "phase_4",
        "build_log",
        %{"text_file" => path},
        exported: true
      )

    {ws, path}
  end

  defp create_session_with_markdown_file_export do
    path = Path.join(System.tmp_dir!(), "destila_test_#{System.unique_integer([:positive])}.md")
    File.write!(path, "# Title\n\nSome **bold** text")
    on_exit(fn -> File.rm(path) end)

    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test Session",
        workflow_type: :brainstorm_idea,
        project_id: nil,
        done_at: DateTime.utc_now(),
        current_phase: 4,
        total_phases: 4
      })

    {:ok, _} =
      Destila.Workflows.upsert_metadata(
        ws.id,
        "phase_4",
        "implementation_plan",
        %{"markdown_file" => path},
        exported: true
      )

    {ws, path}
  end

  describe "text_file sidebar entry" do
    @tag feature: "exported_metadata",
         scenario: "Text file metadata sidebar entry has view button"
    test "shows view button instead of details block", %{conn: conn} do
      {ws, _path} = create_session_with_text_file_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "button[phx-click='open_text_file_modal'][phx-value-id]")
      assert has_element?(view, "[id^='metadata-entry-'] .hero-document-text-micro")
    end

    @tag feature: "exported_metadata",
         scenario: "Text file metadata sidebar entry has view button"
    test "clicking view button opens text file modal", %{conn: conn} do
      {ws, _path} = create_session_with_text_file_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("button[phx-click='open_text_file_modal']") |> render_click()

      assert has_element?(view, "#text-file-modal")
      assert has_element?(view, "#text-file-modal pre")

      modal_html = view |> element("#text-file-modal") |> render()
      assert modal_html =~ "Hello from text file"
      assert modal_html =~ "Build Log"
    end

    @tag feature: "exported_metadata",
         scenario: "Text file metadata sidebar entry has view button"
    test "closing text file modal removes it", %{conn: conn} do
      {ws, _path} = create_session_with_text_file_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("button[phx-click='open_text_file_modal']") |> render_click()
      assert has_element?(view, "#text-file-modal")

      view
      |> element("#text-file-modal button[phx-click='close_text_file_modal']")
      |> render_click()

      refute has_element?(view, "#text-file-modal")
    end
  end

  describe "markdown_file sidebar entry" do
    @tag feature: "exported_metadata",
         scenario: "Markdown file metadata sidebar entry has view button"
    test "shows view button instead of details block", %{conn: conn} do
      {ws, _path} = create_session_with_markdown_file_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "button[phx-click='open_markdown_file_modal'][phx-value-id]")
      assert has_element?(view, "[id^='metadata-entry-'] .hero-document-text-micro")
    end

    @tag feature: "exported_metadata",
         scenario: "Markdown file metadata sidebar entry has view button"
    test "clicking view button opens markdown modal with file content", %{conn: conn} do
      {ws, _path} = create_session_with_markdown_file_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("button[phx-click='open_markdown_file_modal']") |> render_click()

      assert has_element?(view, "#markdown-modal")
      assert has_element?(view, "#markdown-modal-viewer")

      modal_html = view |> element("#markdown-modal") |> render()
      assert modal_html =~ "Implementation Plan"
    end

    @tag feature: "exported_metadata",
         scenario: "Markdown file metadata sidebar entry has view button"
    test "closing markdown file modal removes it", %{conn: conn} do
      {ws, _path} = create_session_with_markdown_file_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("button[phx-click='open_markdown_file_modal']") |> render_click()
      assert has_element?(view, "#markdown-modal")

      view
      |> element("#markdown-modal button[phx-click='close_markdown_modal']")
      |> render_click()

      refute has_element?(view, "#markdown-modal")
    end
  end
end
