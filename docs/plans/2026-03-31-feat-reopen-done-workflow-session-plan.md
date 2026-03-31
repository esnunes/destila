# Plan: Reopen (Un-done) a Completed Workflow Session

**Date:** 2026-03-31
**Type:** Feature

## Goal

Allow users to reopen a workflow session that has been marked as done by adding a "Reopen" button that clears `done_at` and `phase_status`, returning the session to its final phase in an interactive state.

## Context

- `mark_done` handler is at `lib/destila_web/live/workflow_runner_live.ex:163-182`
- It sets `done_at: DateTime.utc_now()` and `phase_status: nil` via `Workflows.update_workflow_session/2`
- `Session.done?/1` checks `not is_nil(done_at)` (`lib/destila/workflows/session.ex:52`)
- `Workflows.classify/1` returns `:done` when `Session.done?` is true — clearing `done_at` will automatically reclassify the session
- The "Mark as Done" button renders at lines 412-424 (visible when on final phase and not done)
- The "Workflow complete" banner renders at lines 455-464 (visible when done)
- No migration needed — `done_at` is already nullable

## Changes

### 1. Add `handle_event("mark_undone")` to WorkflowRunnerLive

**File:** `lib/destila_web/live/workflow_runner_live.ex`

Add a new handler after the existing `mark_done` handler (after line 182):

```elixir
def handle_event("mark_undone", _params, socket) do
  ws = socket.assigns.workflow_session

  {:ok, ws} =
    Workflows.update_workflow_session(ws, %{
      done_at: nil,
      phase_status: nil
    })

  {:noreply, assign(socket, :workflow_session, ws)}
end
```

This mirrors `mark_done` but reverses the operation. No AI message cleanup is needed per requirements. Setting `phase_status: nil` leaves the session in a neutral interactive state on its final phase.

### 2. Replace "Workflow complete" banner with "Reopen" button

**File:** `lib/destila_web/live/workflow_runner_live.ex`

Replace the "Workflow complete" banner (lines 455-464) with a "Reopen" button:

```heex
<div
  :if={@workflow_session && Session.done?(@workflow_session)}
  class="border-t border-base-300 bg-base-200/50 px-4 py-3"
>
  <p class="text-sm text-base-content/50 flex items-center justify-center gap-2">
    <.icon name="hero-check-circle-solid" class="size-4 text-success" />
    <span>Workflow complete</span>
    <button
      phx-click="mark_undone"
      id="reopen-btn"
      class="btn btn-soft btn-sm ml-2"
    >
      <.icon name="hero-arrow-path-micro" class="size-4" /> Reopen
    </button>
  </p>
</div>
```

Key design decisions:
- Uses `btn-soft` (neutral/gray style) instead of `btn-success` to visually distinguish from "Mark as Done"
- Placed inline next to the "Workflow complete" text for discoverability
- Uses `hero-arrow-path-micro` icon to suggest reopening/cycling
- `id="reopen-btn"` for test targeting

### 3. Add LiveView test for `mark_undone`

**File:** `test/destila_web/live/chore_task_workflow_live_test.exs`

Add a new test inside the "Phase 6 - Prompt Generation" describe block (after line 361):

```elixir
@tag feature: @feature, scenario: "Un-done a completed session"
test "reopens a completed workflow via Reopen button", %{conn: conn} do
  ws = create_session_in_phase(6)
  # Mark as done first
  {:ok, ws} = Workflows.update_workflow_session(ws, %{done_at: DateTime.utc_now(), phase_status: nil})

  {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

  assert render(view) =~ "Workflow complete"
  assert has_element?(view, "button[phx-click='mark_undone']")

  view |> element("button[phx-click='mark_undone']") |> render_click()

  refute render(view) =~ "Workflow complete"
  refute has_element?(view, "button[phx-click='mark_undone']")

  # Verify done_at is cleared in DB
  ws = Workflows.get_workflow_session!(ws.id)
  assert is_nil(ws.done_at)
end
```

### 4. Add Gherkin scenario

**File:** `features/chore_task_workflow.feature`

Add after the "Phase 6" scenario (after line 84):

```gherkin
  Scenario: Un-done a completed session
    Given the session is marked as done
    When I click "Reopen"
    Then the workflow should no longer be marked as complete
    And I should see the last phase of the workflow
    And I should be able to continue interacting with the session
```

## Files Modified

| File | Change |
|------|--------|
| `lib/destila_web/live/workflow_runner_live.ex` | Add `handle_event("mark_undone")` handler; add Reopen button to the complete banner |
| `test/destila_web/live/chore_task_workflow_live_test.exs` | Add test for `mark_undone` event |
| `features/chore_task_workflow.feature` | Add "Un-done a completed session" scenario |

## What Does NOT Change

- **No migration** — `done_at` is already nullable
- **No Workflows context changes** — reuses existing `update_workflow_session/2`
- **No AI message cleanup** — completion message stays in history
- **No crafting board changes** — `Workflows.classify/1` and PubSub flow handle reclassification automatically
- **No Engine changes** — the session stays on its final phase; user can continue conversing
