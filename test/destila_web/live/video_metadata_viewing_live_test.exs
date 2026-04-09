defmodule DestilaWeb.VideoMetadataViewingLiveTest do
  @moduledoc """
  LiveView tests for Video Metadata Viewing.
  Feature: features/video_metadata_viewing.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "video_metadata_viewing"

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

  defp create_session_with_video_export do
    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test Session",
        workflow_type: :brainstorm_idea,
        project_id: nil,
        done_at: DateTime.utc_now(),
        current_phase: 4,
        total_phases: 4
      })

    {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

    {:ok, _} =
      Destila.AI.create_message(ai_session.id, %{
        role: :system,
        content: "Here is the video output.",
        raw_response: %{
          "text" => "Here is the video output.",
          "result" => "Here is the video output.",
          "mcp_tool_uses" => [
            %{
              "name" => "mcp__destila__session",
              "input" => %{
                "action" => "export",
                "key" => "demo_video",
                "value" => "/tmp/test.mp4",
                "type" => "video_file"
              }
            }
          ],
          "is_error" => false
        },
        phase: 4,
        workflow_session_id: ws.id
      })

    Destila.Workflows.upsert_metadata(
      ws.id,
      "phase_4",
      "demo_video",
      %{"video_file" => "/tmp/test.mp4"},
      exported: true
    )

    ws
  end

  describe "video card inline" do
    @tag feature: @feature, scenario: "Video card displays with click-to-play controls"
    test "renders a video card with video element", %{conn: conn} do
      ws = create_session_with_video_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "[id^='export-video-']")
      assert has_element?(view, "video")
      assert has_element?(view, "source[type='video/mp4']")
    end

    @tag feature: @feature, scenario: "Video card displays with click-to-play controls"
    test "video source URL points to /media/ endpoint", %{conn: conn} do
      ws = create_session_with_video_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      html = render(view)
      assert html =~ "/media/"
    end

    @tag feature: @feature, scenario: "Video card displays with click-to-play controls"
    test "card header shows humanized key", %{conn: conn} do
      ws = create_session_with_video_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      html = render(view)
      assert html =~ "Demo Video"
    end
  end

  describe "sidebar play button" do
    @tag feature: @feature, scenario: "Open video in modal from sidebar"
    test "sidebar entry has play button", %{conn: conn} do
      ws = create_session_with_video_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "button[phx-click='open_video_modal']")
    end

    @tag feature: @feature, scenario: "Open video in modal from sidebar"
    test "clicking play button opens video modal", %{conn: conn} do
      ws = create_session_with_video_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("button[phx-click='open_video_modal']") |> render_click()

      assert has_element?(view, "#video-modal")
      assert has_element?(view, "#video-modal video")
    end
  end

  describe "video modal" do
    @tag feature: @feature, scenario: "Close video modal"
    test "closing modal removes it from DOM", %{conn: conn} do
      ws = create_session_with_video_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("button[phx-click='open_video_modal']") |> render_click()
      assert has_element?(view, "#video-modal")

      view |> element("#video-modal button[phx-click='close_video_modal']") |> render_click()
      refute has_element?(view, "#video-modal")
    end
  end
end
