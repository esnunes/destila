---
title: "fix: Retry in non-interactive AI conversation stays stuck at awaiting_input"
type: fix
date: 2026-04-01
---

# fix: Retry in non-interactive AI conversation stays stuck at awaiting_input

## Overview

When an error occurs in a non-interactive AI conversation phase and the user clicks "Retry", the workflow remains classified as "Waiting for You" on the dashboard/crafting board instead of moving to "Processing". The retry button in the phase view also stays visible or reappears immediately.

## Root Cause

There are two bugs working together in `AiConversationPhase.handle_event("retry_phase", ...)` (`lib/destila_web/live/phases/ai_conversation_phase.ex:157-176`):

### Bug 1: Phase execution status not updated (primary)

When an error occurs, the Engine's `handle_awaiting_input/1` updates **both** the `phase_execution.status` (to `"awaiting_input"`) and the `workflow_session.phase_status` (to `:awaiting_input`). However, when the user clicks retry and `phase_start_action` returns `:processing`, the retry handler only updates the `workflow_session.phase_status` — it never touches the phase execution record.

This matters because `Workflows.classify/1` checks the phase execution status **first** and only falls back to `workflow_session.phase_status` when the phase execution has no matching status:

```elixir
# lib/destila/workflows.ex:119-133
case Destila.Executions.get_current_phase_execution(workflow_session.id) do
  %{status: status} when status in ["awaiting_input", "awaiting_confirmation"] ->
    :waiting_for_user   # <-- This wins because PE status is still "awaiting_input"

  %{status: "processing"} ->
    :processing

  _ ->
    # Fallback to legacy phase_status — only reached if PE status doesn't match above
    case workflow_session.phase_status do
      status when status in [:awaiting_input, :advance_suggested] -> :waiting_for_user
      :processing -> :processing
      _ -> :processing
    end
end
```

So even after retry successfully updates `workflow_session.phase_status` to `:processing`, the phase execution record still has `status: "awaiting_input"`, causing the dashboard to show "Waiting for You".

### Bug 2: Silent no-op on `:awaiting_input` return (secondary)

The retry handler's `:awaiting_input` branch does nothing:

```elixir
:awaiting_input ->
  {:noreply, socket}  # No-op: status stays stuck
```

For properly configured non-interactive phases (which always have a `system_prompt`), `phase_start_action` should always return `:processing`. However, if an exception occurs during `prompt_fn.(ws)` or `enqueue_ai_worker` (e.g., metadata missing after a failed setup), the LiveView process would crash and remount with stale state, making it appear stuck.

## Proposed Solution

### Change 1: Update phase execution status in retry handler

**File:** `lib/destila_web/live/phases/ai_conversation_phase.ex`

The retry handler must update both `workflow_session.phase_status` AND the `phase_execution.status` to `"processing"` when `phase_start_action` returns `:processing`. This mirrors what the Engine does in `transition_to_phase/2` and `phase_update/3`.

```elixir
def handle_event("retry_phase", _params, socket) do
  ws = socket.assigns.workflow_session
  opts = socket.assigns.opts

  if Keyword.get(opts, :non_interactive, false) && ws.phase_status != :processing do
    # Stop existing session to avoid sending duplicate prompts
    AI.ClaudeSession.stop_for_workflow_session(ws.id)

    # Reload from DB to get fresh state after stopping the session
    ws = Workflows.get_workflow_session!(ws.id)

    case Workflows.phase_start_action(ws) do
      :processing ->
        # Update both workflow session AND phase execution status
        {:ok, ws} = Workflows.update_workflow_session(ws, %{phase_status: :processing})

        case Destila.Executions.get_current_phase_execution(ws.id) do
          nil -> :ok
          pe -> Destila.Executions.update_phase_execution_status(pe, "processing")
        end

        {:noreply, assign(socket, :workflow_session, ws)}

      :awaiting_input ->
        require Logger

        Logger.warning(
          "retry_phase: phase_start_action returned :awaiting_input " <>
            "for non-interactive phase #{ws.current_phase} on workflow_session #{ws.id}"
        )

        {:noreply, socket}
    end
  else
    {:noreply, socket}
  end
end
```

Key differences from current code:

1. **Reload `ws` from DB** (`Workflows.get_workflow_session!/1`) after stopping the ClaudeSession, so `phase_start_action` operates on fresh data.
2. **Use the `{:ok, ws}` return** from `update_workflow_session` instead of manually constructing `%{ws | phase_status: :processing}` — ensures the socket gets the DB-canonical struct.
3. **Update phase execution status** to `"processing"` so `Workflows.classify/1` correctly returns `:processing`.
4. **Log the `:awaiting_input` fallback** instead of silently swallowing it.

### Change 2: None needed for `ensure_ai_session`

After deeper analysis, `ensure_ai_session` does not need changes. The `stop_for_workflow_session` call is synchronous (blocks until the GenServer stops or is killed). The DB `ai_session` record is unaffected — it's the GenServer process that gets stopped, not the DB record. When the Oban worker runs, `ClaudeSession.for_workflow_session/2` will start a fresh GenServer using the existing DB record's `claude_session_id` for resume.

## Files to Modify

1. **`lib/destila_web/live/phases/ai_conversation_phase.ex`** — `handle_event("retry_phase", ...)`:
   - Reload `ws` from DB before calling `phase_start_action`
   - Update phase execution status to `"processing"` alongside `workflow_session.phase_status`
   - Use `{:ok, ws}` return from `update_workflow_session`
   - Log `:awaiting_input` fallback

## How the Fix Aligns with Existing Patterns

The Engine (`lib/destila/executions/engine.ex`) consistently updates both statuses together:

- `transition_to_phase/2` (line 176-183): Sets both `Executions.start_phase(pe, "processing")` and `Workflows.update_workflow_session(reloaded, %{phase_status: :processing})`
- `phase_update/3` (line 90-97): When receiving `:processing`, updates both PE status and WS phase_status
- `handle_awaiting_input/1` (line 143-156): Updates both PE to `"awaiting_input"` and WS to `:awaiting_input`

The retry handler is the only place that updates one without the other.

## Testing Strategy

### Manual Testing

1. Start an ImplementGeneralPrompt workflow and advance to a non-interactive phase (e.g., "Generate Plan")
2. Cause an AI error (disconnect network during AI processing, or temporarily set an invalid API key)
3. Wait for "Something went wrong" message and the Retry button to appear
4. Open the dashboard/crafting board in another tab — verify session shows under "Waiting for You"
5. Click Retry
6. Verify:
   - Typing indicator appears (phase_status is `:processing`)
   - Cancel button replaces retry button
   - Dashboard moves session from "Waiting for You" to "Processing"
   - AI query completes successfully

### Automated Tests

Add tests in the AI conversation phase test file:

1. **Test: retry transitions both workflow session and phase execution to processing**
   - Create a workflow session with `phase_status: :awaiting_input`
   - Create a phase execution with `status: "awaiting_input"`
   - Mount a non-interactive AiConversationPhase
   - Click `retry_phase`
   - Assert `workflow_session.phase_status == :processing`
   - Assert `phase_execution.status == "processing"`
   - Assert an `AiQueryWorker` job is enqueued

2. **Test: retry shows processing UI (typing indicator, cancel button)**
   - Same setup, click `retry_phase`
   - Assert retry button is gone, cancel button is visible

3. **Test: workflow classified as :processing after retry**
   - Same setup, click `retry_phase`
   - Assert `Workflows.classify(ws) == :processing`

## Implementation Steps

1. Apply the retry handler fix (Change 1 above)
2. Run `mix precommit` to verify compilation and existing tests pass
3. Add automated tests for the retry flow
4. Run `mix precommit` again
