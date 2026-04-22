defmodule Destila.AI.Hooks.PreCompactTest do
  use DestilaWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Destila.AI
  alias Destila.AI.Hooks.PreCompact
  alias Destila.Workflows

  defp create_ws(attrs \\ %{}) do
    base = %{
      title: "Test",
      workflow_type: :brainstorm_idea,
      current_phase: 1,
      total_phases: 4,
      user_prompt: "Build a dark mode toggle"
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

  defp build_input(attrs) do
    Map.merge(
      %{
        hook_event_name: "PreCompact",
        session_id: "cs-unset",
        transcript_path: "/tmp/transcript.jsonl",
        cwd: "/tmp",
        trigger: "auto",
        custom_instructions: nil
      },
      attrs
    )
  end

  describe "call/2 happy path" do
    test "wraps phase prompt in <initial-prompt> tags with the reference line" do
      ws = create_ws()
      _ai = create_ai(ws, "cs-1")

      input = build_input(%{session_id: "cs-1", trigger: "auto"})

      assert {:ok, custom_instructions: body} = PreCompact.call(input, nil)
      assert is_binary(body)

      assert body =~ "<initial-prompt>"
      assert body =~ "</initial-prompt>"
      assert body =~ "Build a dark mode toggle"

      assert body =~
               "In the `<initial-prompt>` you can find the initial user prompt for reference."
    end

    test "works regardless of trigger (manual vs auto)" do
      ws = create_ws()
      _ai = create_ai(ws, "cs-manual")

      input = build_input(%{session_id: "cs-manual", trigger: "manual"})

      assert {:ok, custom_instructions: body} = PreCompact.call(input, nil)
      assert body =~ "<initial-prompt>"
      assert body =~ "Build a dark mode toggle"
    end

    test "preserves incoming custom_instructions from the caller" do
      ws = create_ws()
      _ai = create_ai(ws, "cs-with-hint")

      input =
        build_input(%{
          session_id: "cs-with-hint",
          custom_instructions: "focus on TODOs"
        })

      assert {:ok, custom_instructions: body} = PreCompact.call(input, nil)
      assert body =~ "focus on TODOs"
      assert body =~ "<initial-prompt>"
      assert body =~ "Build a dark mode toggle"
    end

    test "uses the current phase's initial prompt, not phase 1" do
      ws = create_ws(%{current_phase: 3})
      _ai = create_ai(ws, "cs-phase-3")

      input = build_input(%{session_id: "cs-phase-3"})

      assert {:ok, custom_instructions: body} = PreCompact.call(input, nil)
      # Phase 3 for brainstorm_idea is "Technical Concerns".
      assert body =~ "<initial-prompt>"
      assert body =~ "exploring technical concerns"
      refute body =~ "Your job is to ask focused questions"
    end
  end

  describe "call/2 phase_number guards" do
    test "returns :ok when workflow's current_phase is zero" do
      ws = create_ws(%{current_phase: 0, total_phases: 4})
      _ai = create_ai(ws, "cs-phase-0")

      input = build_input(%{session_id: "cs-phase-0"})

      assert PreCompact.call(input, nil) == :ok
    end

    test "returns :ok when workflow's current_phase is negative" do
      ws = create_ws(%{current_phase: -1, total_phases: 4})
      _ai = create_ai(ws, "cs-phase-negative")

      input = build_input(%{session_id: "cs-phase-negative"})

      assert PreCompact.call(input, nil) == :ok
    end
  end

  describe "call/2 defensive paths" do
    test "returns :ok when the session_id has no matching AI session" do
      input = build_input(%{session_id: "cs-unknown"})

      assert PreCompact.call(input, nil) == :ok
    end

    test "returns :ok when session_id is nil" do
      input = build_input(%{session_id: nil})

      assert PreCompact.call(input, nil) == :ok
    end

    test "returns :ok when AI session references a non-existent workflow_session_id" do
      # Insert an AI session, then delete its workflow session so the lookup breaks.
      ws = create_ws()
      ai = create_ai(ws, "cs-orphan")
      Destila.Repo.delete!(ws)

      input = build_input(%{session_id: ai.claude_session_id})

      assert PreCompact.call(input, nil) == :ok
    end

    test "returns :ok when the workflow's current_phase is out of range" do
      ws = create_ws(%{current_phase: 99, total_phases: 4})
      _ai = create_ai(ws, "cs-out-of-range")

      input = build_input(%{session_id: "cs-out-of-range"})

      assert PreCompact.call(input, nil) == :ok
    end

    test "returns :ok when called with a non-PreCompact hook event" do
      assert PreCompact.call(%{hook_event_name: "PostToolUse"}, nil) == :ok
    end
  end

  describe "call/2 error recovery" do
    test "returns :ok and logs a warning when the call itself raises" do
      # Pass an input missing required keys — the pattern match on the main
      # clause falls through to the catch-all, which returns :ok. Use a shape
      # that forces the main clause to be entered with a broken session_id
      # type so Repo.get_by raises, exercising the rescue.
      log =
        capture_log(fn ->
          assert PreCompact.call(
                   %{hook_event_name: "PreCompact", session_id: :not_a_binary},
                   nil
                 ) == :ok
        end)

      assert log =~ "PreCompact hook"
    end
  end
end
