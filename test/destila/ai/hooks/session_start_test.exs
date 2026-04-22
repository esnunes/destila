defmodule Destila.AI.Hooks.SessionStartTest do
  use DestilaWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Destila.AI
  alias Destila.AI.Hooks.SessionStart
  alias Destila.Workflows

  defp create_ws(attrs \\ %{}) do
    base = %{
      title: "Test",
      workflow_type: :brainstorm_idea,
      current_phase: 1,
      total_phases: 4
    }

    {:ok, ws} = Workflows.insert_workflow_session(Map.merge(base, attrs))
    ws
  end

  defp create_ai(ws, claude_session_id) do
    {:ok, ai} =
      AI.create_ai_session(%{
        workflow_session_id: ws.id,
        claude_session_id: claude_session_id
      })

    ai
  end

  defp input(attrs) do
    Map.merge(%{hook_event_name: "SessionStart", source: "compact"}, attrs)
  end

  describe "call/2 with SessionStart source=compact" do
    test "injects the current phase's initial prompt as additional_context" do
      ws = create_ws()
      _ai = create_ai(ws, "claude-compact-1")

      assert {:ok, additional_context: ctx} =
               SessionStart.call(input(%{session_id: "claude-compact-1"}), nil)

      assert ctx =~ "<initial-prompt>"
      assert ctx =~ "</initial-prompt>"
      assert ctx =~ "The conversation was just compacted."
      assert ctx =~ "You are helping clarify a coding task."
      assert ctx =~ "In the `<initial-prompt>`"
    end

    test "resolves the initial prompt for a later phase (phase 3)" do
      ws = create_ws(%{current_phase: 3})
      _ai = create_ai(ws, "claude-compact-3")

      assert {:ok, additional_context: ctx} =
               SessionStart.call(input(%{session_id: "claude-compact-3"}), nil)

      assert ctx =~ "exploring technical concerns"
    end
  end

  describe "call/2 pass-through" do
    test "returns :ok for SessionStart with source=startup" do
      ws = create_ws()
      _ai = create_ai(ws, "claude-startup")

      assert SessionStart.call(
               input(%{source: "startup", session_id: "claude-startup"}),
               nil
             ) == :ok
    end

    test "returns :ok for SessionStart with source=resume" do
      ws = create_ws()
      _ai = create_ai(ws, "claude-resume")

      assert SessionStart.call(
               input(%{source: "resume", session_id: "claude-resume"}),
               nil
             ) == :ok
    end

    test "returns :ok for SessionStart with source=clear" do
      ws = create_ws()
      _ai = create_ai(ws, "claude-clear")

      assert SessionStart.call(
               input(%{source: "clear", session_id: "claude-clear"}),
               nil
             ) == :ok
    end

    test "returns :ok for a non-SessionStart event" do
      assert SessionStart.call(
               %{hook_event_name: "PreToolUse", session_id: "whatever"},
               nil
             ) == :ok
    end

    test "returns :ok when session_id is nil" do
      assert SessionStart.call(input(%{session_id: nil}), nil) == :ok
    end

    test "returns :ok when session_id is missing" do
      assert SessionStart.call(input(%{}), nil) == :ok
    end

    test "returns :ok when session_id is an empty string" do
      assert SessionStart.call(input(%{session_id: ""}), nil) == :ok
    end

    test "returns :ok when the session_id is unknown" do
      assert SessionStart.call(input(%{session_id: "does-not-exist"}), nil) == :ok
    end

    test "returns :ok when the AI session's workflow session has been deleted" do
      ws = create_ws()
      _ai = create_ai(ws, "claude-orphan")
      Destila.Repo.delete!(ws)

      assert SessionStart.call(input(%{session_id: "claude-orphan"}), nil) == :ok
    end

    test "returns :ok when current_phase exceeds the workflow's phases" do
      ws = create_ws(%{current_phase: 99})
      _ai = create_ai(ws, "claude-oob")

      assert SessionStart.call(input(%{session_id: "claude-oob"}), nil) == :ok
    end

    test "returns :ok when current_phase is zero" do
      ws = create_ws(%{current_phase: 0})
      _ai = create_ai(ws, "claude-zero")

      assert SessionStart.call(input(%{session_id: "claude-zero"}), nil) == :ok
    end
  end

  describe "call/2 rescue path" do
    test "logs a warning and returns :ok when the prompt function raises" do
      ws = create_ws()
      _ai = create_ai(ws, "claude-boom")

      log =
        capture_log(fn ->
          assert SessionStart.call(
                   input(%{session_id: {:bad, :term}}),
                   nil
                 ) == :ok
        end)

      assert log =~ "SessionStart hook failed"
    end
  end
end
