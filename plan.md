# Bug Fix: Session stays in "Waiting for You" during AI processing after first message

## Problem

When a user sends a message to the AI after the initial AI response, the session
should transition to "AI Processing" on the crafting board. Instead, it stays in
"Waiting for You."

This only happens **after the first message** — the initial phase start correctly
shows "AI Processing" because `transition_to_phase` explicitly updates both the
`phase_execution.status` and `phase_status`.

## Root Cause

The `classify/1` function in `Destila.Workflows` (line 113-139) determines the
crafting board section by checking `phase_execution.status` **first**, falling
back to `phase_status` only when the phase execution doesn't match a known state.

The bug is in `Destila.Executions.Engine.phase_update/3` (line 53-69). When the
workflow returns `:processing` (user sent a message, AI worker enqueued), the
engine only updates the legacy `phase_status` field:

```elixir
:processing ->
  Workflows.update_workflow_session(ws, %{phase_status: :processing})
```

It does **not** update `phase_execution.status` to `"processing"`. Since the
phase execution was previously set to `"awaiting_input"` (after the first AI
response), `classify/1` sees `"awaiting_input"` and returns `:waiting_for_user`.

### Timeline of the bug

1. Phase starts → `transition_to_phase` → `phase_execution.status = "processing"`, `phase_status = :processing` → **classified as `:ai_processing`** ✅
2. AI responds → `phase_update` returns `:awaiting_input` → `handle_awaiting_input` updates `phase_execution.status = "awaiting_input"`, `phase_status = :conversing` → **classified as `:waiting_for_user`** ✅
3. User sends message → `phase_update` returns `:processing` → only `phase_status = :processing` updated, `phase_execution.status` still `"awaiting_input"` → **classified as `:waiting_for_user`** ❌ (should be `:ai_processing`)
4. AI responds → same as step 2
5. User sends another message → same as step 3 — bug repeats

## Fix

### File: `lib/destila/executions/engine.ex`

In `phase_update/3`, update the `phase_execution.status` to `"processing"` when
the workflow returns `:processing`. This mirrors what `handle_awaiting_input`
already does for the `:awaiting_input` case.

**Current code (lines 57-58):**
```elixir
:processing ->
  Workflows.update_workflow_session(ws, %{phase_status: :processing})
```

**Fixed code:**
```elixir
:processing ->
  case Executions.get_current_phase_execution(ws.id) do
    nil -> :ok
    pe when pe.status in ["awaiting_input", "awaiting_confirmation"] ->
      Executions.update_phase_execution_status(pe, "processing")
    _pe -> :ok
  end

  Workflows.update_workflow_session(ws, %{phase_status: :processing})
```

This follows the same pattern as `handle_awaiting_input/1` (lines 104-118),
which only transitions from `"processing"` → `"awaiting_input"`. The fix
symmetrically transitions from `"awaiting_input"` or `"awaiting_confirmation"`
→ `"processing"`.

### No other changes needed

- `classify/1` already handles `"processing"` phase execution status correctly
  (line 127-128)
- The UI (`ai_conversation_phase.ex`) already shows the typing indicator and
  disables input when `phase_status == :processing` (lines 243-245, 321)
- Both workflow modules (`PromptChoreTaskWorkflow` and
  `ImplementGeneralPromptWorkflow`) correctly return `:processing` from
  `phase_update_action` when a user message triggers an AI query

## Testing

1. Start a workflow and enter an AI conversation phase (e.g., "Task Description")
2. Wait for the AI's first response (session should be in "Waiting for You")
3. Send a reply message
4. Verify the session moves to "AI Processing" on the crafting board
5. Wait for the AI response
6. Verify it returns to "Waiting for You"
7. Repeat steps 3-6 to confirm consistent behavior
