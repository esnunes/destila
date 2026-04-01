---
title: "fix: Retry in non-interactive AI conversation stays stuck at awaiting_input"
type: fix
date: 2026-04-01
---

# fix: Retry in non-interactive AI conversation stays stuck at awaiting_input

## Overview

When an error occurs in a non-interactive AI conversation phase and the user clicks "Retry", the phase status remains `:awaiting_input` instead of transitioning back to `:processing`. The retry button stays visible but does nothing.

## Root Cause

In `AiConversationPhase.handle_event("retry_phase", ...)` (line 157-176), the handler calls `Workflows.phase_start_action(ws)` and pattern-matches on the result. When `phase_start_action` returns `:awaiting_input`, the handler does nothing (`{:noreply, socket}`), leaving the UI stuck.

The reason `phase_start_action` can return `:awaiting_input` on retry: this function uses `ws` from socket assigns, which still carries the **stale** workflow session state (with `phase_status: :awaiting_input`). For `ImplementGeneralPromptWorkflow`, the phase_start_action calls `handle_session_strategy(ws, phase_number)` before `ensure_ai_session(ws)`. The `handle_session_strategy` call for `:resume` phases is a no-op, but `ensure_ai_session` looks up the existing AI session. If the previous AI session was cleaned up by the `ClaudeSession.stop_for_workflow_session(ws.id)` call on line 163 (the line just above), then `ensure_ai_session` creates a new one and proceeds — returning `:processing`. But if there's any mismatch (e.g. the session is still there but in an error state, or the phase doesn't have a `system_prompt`), it returns `:awaiting_input`.

However, the **primary** bug path is simpler: `phase_start_action` does return `:processing` for phases with a `system_prompt`, which re-enqueues the AI worker. But if it ever returns `:awaiting_input` (defensive edge case or a phase config issue), the handler silently swallows the retry attempt.

The fix should ensure that the `:awaiting_input` branch in the retry handler doesn't silently do nothing.

## Proposed Solution

### Change 1: Handle `:awaiting_input` in retry handler

**File:** `lib/destila_web/live/phases/ai_conversation_phase.ex`

Replace the retry handler's `:awaiting_input` no-op with logic that still transitions status to `:processing` and re-enqueues the AI worker via the Engine, since this is a non-interactive phase that should always auto-process.

```elixir
def handle_event("retry_phase", _params, socket) do
  ws = socket.assigns.workflow_session
  opts = socket.assigns.opts

  if Keyword.get(opts, :non_interactive, false) && ws.phase_status != :processing do
    # Stop existing session to avoid sending duplicate prompts
    AI.ClaudeSession.stop_for_workflow_session(ws.id)

    # Reload the workflow session from DB to get fresh state
    ws = Workflows.get_workflow_session!(ws.id)

    case Workflows.phase_start_action(ws) do
      :processing ->
        Workflows.update_workflow_session(ws, %{phase_status: :processing})
        {:noreply, assign(socket, :workflow_session, %{ws | phase_status: :processing})}

      :awaiting_input ->
        # Non-interactive phases should not stay in awaiting_input on retry.
        # This can happen if the phase has no system_prompt or the session
        # couldn't be initialized. Keep status as-is so user sees the retry
        # button and can try again, but log for debugging.
        require Logger
        Logger.warning("retry_phase: phase_start_action returned :awaiting_input for non-interactive phase #{ws.current_phase} on workflow_session #{ws.id}")
        {:noreply, socket}
    end
  else
    {:noreply, socket}
  end
end
```

**Rationale for reloading `ws`:** The `ws` in socket assigns is stale — it still has whatever data was present when the component last updated. The `ClaudeSession.stop_for_workflow_session` call on the line above may have side effects on the session state. Reloading from DB ensures `phase_start_action` operates on current data. This is the most likely fix for the bug: `phase_start_action` with fresh `ws` data should correctly find the `system_prompt` and return `:processing`.

### Change 2 (if needed): Verify `handle_session_strategy` + `ensure_ai_session` after stop

If the reload alone doesn't fix it, the issue is that `ClaudeSession.stop_for_workflow_session` runs asynchronously and the AI session record may not be cleaned up by the time `phase_start_action` → `ensure_ai_session` runs. In that case, `ensure_ai_session` finds the old (now-stopped) session and doesn't create a new one, causing the prompt function to succeed but the worker to fail immediately.

**File:** `lib/destila/workflows/implement_general_prompt_workflow.ex` (and `prompt_chore_task_workflow.ex`)

Ensure `ensure_ai_session` handles the case where the existing session was stopped. This would be a deeper fix if Change 1 alone is insufficient.

## Files to Modify

1. **`lib/destila_web/live/phases/ai_conversation_phase.ex`** — `handle_event("retry_phase", ...)`: Reload `ws` from DB before calling `phase_start_action`. Add logging for the `:awaiting_input` fallback.
2. **`lib/destila/workflows/implement_general_prompt_workflow.ex`** — (possibly) `ensure_ai_session/1`: Handle stopped sessions.
3. **`lib/destila/workflows/prompt_chore_task_workflow.ex`** — (possibly) Same as above if the pattern is shared.

## Testing Strategy

### Manual Testing

1. Start a workflow with non-interactive phases (e.g., ImplementGeneralPrompt workflow)
2. Cause an AI error (e.g., disconnect network during AI processing, or use an invalid API key)
3. Wait for the phase to show "Something went wrong" message and the Retry button
4. Click Retry
5. Verify the phase transitions to `:processing` (typing indicator appears, cancel button replaces retry button)
6. Verify the AI query is re-enqueued and eventually completes

### Automated Tests

Add a test in the AI conversation phase test file:

- **Test: retry on non-interactive phase transitions to processing** — Mount a non-interactive AiConversationPhase with `phase_status: :awaiting_input` (simulating post-error state), click "retry_phase", assert the status transitions to `:processing`.
- **Test: retry on non-interactive phase re-enqueues AI worker** — Same setup, but also assert an `AiQueryWorker` job is enqueued after retry.

## Implementation Steps

1. Add `ws` reload from DB in the retry handler (Change 1)
2. Run `mix precommit` to verify no compilation errors or test failures
3. Manual test with a real workflow to confirm the fix
4. Add automated test for the retry flow
5. Run `mix precommit` again
