# Fix: Disable "Mark as Done" button while processing instead of hiding it

## Context

Currently the "Mark as Done" button is **hidden** (`:if` guard) when `@phase_status == :processing`. The user wants to **show the button but disable it** during processing, so the user knows the action exists but isn't available yet.

**File:** `lib/destila_web/live/workflow_runner_live.ex` — lines 509-522

Current implementation:

```heex
<button
  :if={
    @workflow_session &&
      @workflow_session.current_phase == @workflow_session.total_phases &&
      !Session.done?(@workflow_session) &&
      @phase_status != :processing
  }
  phx-click="mark_done"
  id="mark-done-btn"
  class="btn btn-success btn-sm"
>
  <.icon name="hero-check-micro" class="size-4" /> Mark as Done
</button>
```

The `@phase_status != :processing` condition hides the entire button.

## Plan

### Step 1 — Update the template to disable instead of hide

Move the `:processing` check out of `:if` and into a `disabled` attribute.

Replace lines 509-522 with:

```heex
<button
  :if={
    @workflow_session &&
      @workflow_session.current_phase == @workflow_session.total_phases &&
      !Session.done?(@workflow_session)
  }
  phx-click="mark_done"
  id="mark-done-btn"
  disabled={@phase_status == :processing}
  class="btn btn-success btn-sm"
>
  <.icon name="hero-check-micro" class="size-4" /> Mark as Done
</button>
```

Key changes:
- Remove `@phase_status != :processing` from the `:if` guard
- Add `disabled={@phase_status == :processing}` HTML attribute (prevents click + provides a11y)
- Keep the existing `btn btn-success btn-sm` class unchanged — daisyUI's `.btn` already styles
  `:disabled` / `[disabled]` buttons with muted colors, `pointer-events: none`, and no box-shadow,
  so no class-swapping is needed

Notes:
- The HTML `disabled` attribute prevents `phx-click` from firing in LiveView
- The `SessionProcess` gen_statem also rejects `mark_done` calls in `:processing` state as a backend safeguard

### Step 2 — Update the feature file scenario

**File:** `features/brainstorm_idea_workflow.feature` — lines 87-91

Change from:

```gherkin
Scenario: Mark as Done is hidden while last phase is processing
  Given the session is in Phase 4 - Prompt Generation
  And the phase is still processing
  Then I should not see a "Mark as Done" button
  And the session should not be marked as complete
```

To:

```gherkin
Scenario: Mark as Done is disabled while last phase is processing
  Given the session is in Phase 4 - Prompt Generation
  And the phase is still processing
  Then the "Mark as Done" button should be visible but disabled
  And the session should not be marked as complete
```

### Step 3 — Update the test

**File:** `test/destila_web/live/brainstorm_idea_workflow_live_test.exs` — lines 360-373

Change the test to assert the button is present but disabled, instead of absent:

```elixir
@tag feature: @feature, scenario: "Mark as Done is disabled while last phase is processing"
test "disables Mark as Done while the last phase is still processing", %{conn: conn} do
  ws = create_session_in_phase(4, pe_status: :processing)
  {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

  assert render(view) =~ "Phase 4/4"
  assert has_element?(view, "#mark-done-btn[disabled]")
end
```

Key changes:
- Scenario tag updated to match the renamed feature scenario
- Test name updated to "disables" instead of "hides"
- Assert the button **exists** with the `disabled` attribute (`#mark-done-btn[disabled]`) instead of `refute has_element?`
- Remove the defensive `render_hook` assertion — the HTML `disabled` attribute + backend gen_statem guard is sufficient; testing via `render_hook` was testing a scenario that can't happen through the UI

## Files changed

| File | Change |
|---|---|
| `lib/destila_web/live/workflow_runner_live.ex` | Template: disable button instead of hiding |
| `features/brainstorm_idea_workflow.feature` | Update scenario text |
| `test/destila_web/live/brainstorm_idea_workflow_live_test.exs` | Assert disabled instead of absent |
