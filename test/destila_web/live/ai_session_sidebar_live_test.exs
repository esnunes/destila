defmodule DestilaWeb.AiSessionSidebarLiveTest do
  @moduledoc """
  LiveView tests for the AI Sessions section in the workflow runner right sidebar.
  Feature: features/ai_session_sidebar.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Destila.AI
  alias Destila.AI.AlivenessTracker

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

  defp create_session do
    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test Session",
        workflow_type: :brainstorm_idea,
        project_id: nil,
        done_at: DateTime.utc_now(),
        current_phase: 4,
        total_phases: 4
      })

    ws
  end

  defp create_ai_session(ws, attrs \\ %{}) do
    {:ok, ai} =
      AI.create_ai_session(
        Map.merge(
          %{
            workflow_session_id: ws.id,
            worktree_path: System.tmp_dir!(),
            claude_session_id: Ecto.UUID.generate()
          },
          attrs
        )
      )

    ai
  end

  describe "AI Sessions sidebar section" do
    @tag feature: "ai_session_sidebar",
         scenario: "AI Sessions section renders between Workflow Session and Exported Metadata"
    test "section container is rendered", %{conn: conn} do
      ws = create_session()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#ai-sessions-section")
    end

    @tag feature: "ai_session_sidebar",
         scenario: "AI Sessions section lists every AI session for the workflow"
    test "renders one row per AI session with a link to the detail page", %{conn: conn} do
      ws = create_session()
      ai1 = create_ai_session(ws)
      ai2 = create_ai_session(ws)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#ai-session-row-#{ai1.id}")
      assert has_element?(view, "#ai-session-row-#{ai2.id}")

      assert has_element?(
               view,
               ~s|#ai-session-row-#{ai1.id}[href="/sessions/#{ws.id}/ai/#{ai1.id}"]|
             )

      assert has_element?(
               view,
               ~s|#ai-session-row-#{ai2.id}[href="/sessions/#{ws.id}/ai/#{ai2.id}"]|
             )
    end

    @tag feature: "ai_session_sidebar", scenario: "Empty state when no AI sessions exist"
    test "shows empty state when no AI sessions exist", %{conn: conn} do
      ws = create_session()
      {:ok, view, html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#ai-sessions-section")
      assert html =~ "No AI sessions yet"
    end

    @tag feature: "ai_session_sidebar",
         scenario: "AI Sessions section lists every AI session for the workflow"
    test "rows are rendered in ascending order (oldest first)", %{conn: conn} do
      ws = create_session()
      ai_old = create_ai_session(ws)
      # ensure distinct inserted_at ordering
      Process.sleep(10)
      ai_new = create_ai_session(ws)

      {:ok, _view, html} = live(conn, ~p"/sessions/#{ws.id}")

      old_idx = :binary.match(html, "ai-session-row-#{ai_old.id}") |> elem(0)
      new_idx = :binary.match(html, "ai-session-row-#{ai_new.id}") |> elem(0)

      assert old_idx < new_idx
    end

    @tag feature: "ai_session_sidebar",
         scenario: "AI session row displays the creation time in the browser timezone"
    test "row includes an ISO timestamp hook for browser-local formatting", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      {:ok, view, html} = live(conn, ~p"/sessions/#{ws.id}")

      iso = DateTime.to_iso8601(ai.inserted_at)

      assert has_element?(view, "#ai-session-time-#{ai.id}")
      assert html =~ ~s|data-ts="#{iso}"|
    end
  end

  describe "initial aliveness state" do
    @tag feature: "ai_session_sidebar",
         scenario: "Running AI session shows a green aliveness dot"
    test "row shows a green dot when AlivenessTracker reports the session as alive", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      :ets.insert(:ai_session_aliveness, {{:ai, ai.id}, true})

      try do
        {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

        assert has_element?(view, ~s|#ai-session-row-#{ai.id} .bg-success|)
      after
        :ets.delete(:ai_session_aliveness, {:ai, ai.id})
      end
    end

    @tag feature: "ai_session_sidebar",
         scenario: "Inactive AI session shows a muted aliveness dot"
    test "row shows a muted dot when AlivenessTracker reports the session as inactive", %{
      conn: conn
    } do
      ws = create_session()
      ai = create_ai_session(ws)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      refute has_element?(view, ~s|#ai-session-row-#{ai.id} .bg-success|)
    end
  end

  describe "row navigation" do
    @tag feature: "ai_session_sidebar",
         scenario: "Clicking a row opens the AI Session Debug Detail page"
    test "row link navigates to the AI Session Debug Detail page for that session", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(
               view,
               ~s|#ai-session-row-#{ai.id}[href="/sessions/#{ws.id}/ai/#{ai.id}"]|
             )
    end
  end

  describe "live aliveness updates" do
    @tag feature: "ai_session_sidebar",
         scenario: "Aliveness dot toggles to green in real time when a session starts"
    test "broadcasting an ai-aliveness-change updates the row without reload", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      Phoenix.PubSub.broadcast(
        Destila.PubSub,
        AlivenessTracker.topic(),
        {:aliveness_changed_ai, ai.id, true}
      )

      _ = render(view)

      assert has_element?(
               view,
               ~s|#ai-session-row-#{ai.id} .bg-success|
             )
    end

    @tag feature: "ai_session_sidebar",
         scenario: "Aliveness dot toggles to muted in real time when a session stops"
    test "broadcasting a false ai-aliveness-change reverts the row to muted", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      Phoenix.PubSub.broadcast(
        Destila.PubSub,
        AlivenessTracker.topic(),
        {:aliveness_changed_ai, ai.id, true}
      )

      _ = render(view)

      Phoenix.PubSub.broadcast(
        Destila.PubSub,
        AlivenessTracker.topic(),
        {:aliveness_changed_ai, ai.id, false}
      )

      _ = render(view)

      refute has_element?(view, ~s|#ai-session-row-#{ai.id} .bg-success|)
    end

    @tag feature: "ai_session_sidebar", scenario: "Workflow header aliveness dot is unaffected"
    test "AI-specific aliveness broadcast does not disturb workflow-level handler", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      Phoenix.PubSub.broadcast(
        Destila.PubSub,
        AlivenessTracker.topic(),
        {:aliveness_changed_ai, ai.id, true}
      )

      assert render(view) =~ "ai-sessions-section"
    end
  end

  describe "usage subtitle" do
    defp create_usage_message(ws, ai, overrides \\ %{}) do
      raw =
        Map.merge(
          %{
            "usage" => %{
              "input_tokens" => 120,
              "output_tokens" => 80,
              "cache_read_input_tokens" => 0,
              "cache_creation_input_tokens" => 0
            },
            "total_cost_usd" => 0.0123,
            "duration_ms" => 4200.0
          },
          overrides
        )

      {:ok, msg} =
        AI.create_message(ai.id, %{
          workflow_session_id: ws.id,
          role: :system,
          content: "",
          raw_response: raw,
          phase: 1
        })

      msg
    end

    @tag feature: "ai_session_sidebar",
         scenario: "AI session row shows a usage subtitle with turns, cost, and duration"
    test "row renders a subtitle with turn count, cost, and duration", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)
      _ = create_usage_message(ws, ai)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#ai-session-usage-#{ai.id}")
      assert has_element?(view, "#ai-session-usage-#{ai.id} [data-subtitle-turns]", "1 turn")
      assert has_element?(view, "#ai-session-usage-#{ai.id} [data-subtitle-cost]", "$0.0123")
      assert has_element?(view, "#ai-session-usage-#{ai.id} [data-subtitle-duration]", "4.2s")
    end

    @tag feature: "ai_session_sidebar",
         scenario: "AI session row without recorded usage hides the subtitle"
    test "row without usage does not render a subtitle", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#ai-session-row-#{ai.id}")
      refute has_element?(view, "#ai-session-usage-#{ai.id}")
    end

    @tag feature: "ai_session_sidebar",
         scenario: "Usage subtitle refreshes live when a new turn is recorded"
    test "subtitle appears live after a new system message is inserted", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      refute has_element?(view, "#ai-session-usage-#{ai.id}")

      _ = create_usage_message(ws, ai)
      _ = render(view)

      assert has_element?(view, "#ai-session-usage-#{ai.id}")
      assert has_element?(view, "#ai-session-usage-#{ai.id} [data-subtitle-turns]", "1 turn")
    end
  end
end
