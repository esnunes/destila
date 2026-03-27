---
title: "feat: Redirect to crafting board after archiving session"
type: feat
date: 2026-03-27
---

# Redirect to Crafting Board After Archiving Session

When a user archives a session from the session detail page, redirect them to `/crafting` instead of staying on the page. The "Session archived" flash message displays on the crafting board.

## Acceptance Criteria

- [x] Archiving a session redirects the user to the crafting board (`/crafting`)
- [x] The flash message "Session archived" appears on the crafting board after redirect
- [x] Unarchive flow is unchanged — user stays on session detail page
- [x] The `data-confirm` dialog text remains unchanged
- [x] Gherkin scenario updated to reflect redirect behavior
- [x] Test updated to assert redirect and flash on crafting board

## Implementation

### 1. Update `handle_event("archive_session", ...)` in `workflow_runner_live.ex`

**File:** `lib/destila_web/live/workflow_runner_live.ex` (lines 116-123)

**Current:**

```elixir
def handle_event("archive_session", _params, socket) do
  {:ok, ws} = WorkflowSessions.archive_workflow_session(socket.assigns.workflow_session)

  {:noreply,
   socket
   |> assign(:workflow_session, ws)
   |> put_flash(:info, "Session archived")}
end
```

**New:**

```elixir
def handle_event("archive_session", _params, socket) do
  {:ok, _ws} = WorkflowSessions.archive_workflow_session(socket.assigns.workflow_session)

  {:noreply,
   socket
   |> put_flash(:info, "Session archived")
   |> push_navigate(to: ~p"/crafting")}
end
```

This follows the existing pattern at lines 91-93 of the same file (`put_flash` + `push_navigate` for "Session not found").

### 2. Update Gherkin scenario in `features/session_archiving.feature`

Replace the "Archive a session from the session detail page" scenario (lines 11-15):

```gherkin
Scenario: Archive a session from the session detail page
  Given I am viewing a session titled "Fix login bug"
  When I click the "Archive" button
  Then I should be redirected to the crafting board
  And I should see a flash message confirming the session was archived
```

### 3. Update test in `test/destila_web/live/session_archiving_live_test.exs`

Rewrite the archive test (lines ~41-68) to assert:
- User is redirected to `/crafting` after archive
- Flash message "Session archived" is visible on the crafting board
- The archived session is not listed on the crafting board

## References

- Existing `put_flash` + `push_navigate` pattern: `workflow_runner_live.ex:91-93`
- Archive handler: `workflow_runner_live.ex:116-123`
- Gherkin feature: `features/session_archiving.feature:11-15`
- Test file: `test/destila_web/live/session_archiving_live_test.exs`
