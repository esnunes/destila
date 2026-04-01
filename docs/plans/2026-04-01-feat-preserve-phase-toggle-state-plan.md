---
title: "feat: Preserve manual phase expand/collapse state across server re-renders"
type: feat
date: 2026-04-01
---

# feat: Preserve manual phase expand/collapse state across server re-renders

## Overview

Phase sections in the AI conversation UI use `<details open={phase >= @phase_number}>` to control expand/collapse state. This attribute recomputes on every LiveView re-render (PubSub updates, new messages, phase status changes), overriding any manual user toggle. If a user expands a collapsed previous phase to review it, or collapses the current phase to reduce noise, the next server update snaps it back.

## Solution

Add a colocated JS hook (`.PhaseToggle`) on each `<details>` element in `ai_conversation_phase.ex`. The hook tracks user-initiated toggles and restores them after LiveView DOM patches, while leaving the server-computed default in place when the user hasn't interacted.

### Key design decisions

1. **Colocated hook** (not external) — keeps the logic close to the template, consistent with the existing `.PromptCard` pattern in `chat_components.ex`
2. **Client-side state only** — overrides are stored in a module-level `Map` keyed by element ID; no server round-trips needed and no persistence across full page reloads (intentional)
3. **Server default preserved** — the `open={phase >= @phase_number}` attribute stays in the template; the hook only intervenes when the user has explicitly toggled away from the default
4. **Override cleanup** — when the server's new default matches the user's override (e.g., after a phase advance), the override is cleared to avoid stale state accumulation

## Files to Modify

1. **`lib/destila_web/live/phases/ai_conversation_phase.ex`** — Add the `.PhaseToggle` colocated hook script and wire it to `<details>` elements
2. **`features/brainstorm_idea_workflow.feature`** — Add two new Gherkin scenarios
3. **`test/destila_web/live/brainstorm_idea_workflow_live_test.exs`** — Add tests for the new scenarios

## Implementation Steps

### Step 1: Add the `.PhaseToggle` colocated hook to `ai_conversation_phase.ex`

Add a `<script :type={Phoenix.LiveView.ColocatedHook} name=".PhaseToggle">` block inside the `render/1` function, after the closing `</div>` of the main container.

The hook must:

```javascript
// Module-level map: element ID → boolean (user's desired open state)
const userOverrides = new Map();

export default {
  mounted() {
    // Track the server-computed default for this element
    this._serverOpen = this.el.hasAttribute("open");

    // Listen for user-initiated toggles on the <details> element
    this.el.addEventListener("toggle", (e) => {
      // During an `updated()` restore cycle, we programmatically set `open`.
      // The `_restoring` flag prevents that from being treated as a user toggle.
      if (this._restoring) return;

      const isOpen = this.el.hasAttribute("open");

      // Only record an override if the user toggled away from the server default
      if (isOpen !== this._serverOpen) {
        userOverrides.set(this.el.id, isOpen);
      } else {
        // User toggled back to match server — clear the override
        userOverrides.delete(this.el.id);
      }
    });
  },

  updated() {
    // After LiveView patches the DOM, capture what the server wants
    this._serverOpen = this.el.hasAttribute("open");

    // If the user has an override for this phase, restore it
    if (userOverrides.has(this.el.id)) {
      const desired = userOverrides.get(this.el.id);

      // If the server's new default now matches the user's preference,
      // the override is redundant — clear it
      if (desired === this._serverOpen) {
        userOverrides.delete(this.el.id);
        return;
      }

      // Restore the user's preference
      this._restoring = true;
      if (desired) {
        this.el.setAttribute("open", "");
      } else {
        this.el.removeAttribute("open");
      }

      // Use requestAnimationFrame to clear the flag after the toggle event fires
      requestAnimationFrame(() => {
        this._restoring = false;
      });
    }
  },

  destroyed() {
    userOverrides.delete(this.el.id);
  }
}
```

**Critical implementation notes:**

- The `_restoring` flag prevents the programmatic `open` attribute change in `updated()` from being captured as a user toggle (the native `toggle` event fires for both user and programmatic changes)
- `_serverOpen` is captured at the start of `updated()`, **before** any restoration, so it always reflects what the server intended
- `requestAnimationFrame` is used to clear the `_restoring` flag because the `toggle` event fires synchronously when the attribute changes, but we want to ensure it's cleared after the event handler runs
- The `userOverrides` map is module-scoped (shared across all instances) because each `<details>` has a unique `id`, so there's no collision risk; this avoids needing instance-level state that could be lost on hook re-creation

### Step 2: Wire the hook to `<details>` elements in the template

In `ai_conversation_phase.ex`, modify the `<details>` element (line 218) to add `phx-hook` and a unique `id`:

**Before:**
```heex
<details
  class={["phase-section", phase == elem(hd(@phase_groups), 0) && "first-phase"]}
  open={phase >= @phase_number}
>
```

**After:**
```heex
<details
  id={"phase-section-#{phase}"}
  phx-hook=".PhaseToggle"
  class={["phase-section", phase == elem(hd(@phase_groups), 0) && "first-phase"]}
  open={phase >= @phase_number}
>
```

- `id` is required for `phx-hook` (LiveView enforces this)
- The id format `phase-section-{phase}` is stable across re-renders since phase numbers don't change
- `phx-update="ignore"` is NOT used here — the hook needs LiveView to continue patching the DOM so it can detect server-side changes and selectively override them

### Step 3: Verify `ScrollBottom` hook compatibility

The `ScrollBottom` hook lives on `#chat-messages` (the scrollable container wrapping all phase sections). The `.PhaseToggle` hook lives on individual `<details>` elements inside that container. They operate on different elements and don't interfere:

- `ScrollBottom` sets `scrollTop = scrollHeight` on the container
- `.PhaseToggle` sets/removes the `open` attribute on `<details>` children

No changes needed to `ScrollBottom`. However, note that when `.PhaseToggle` restores a collapsed state, the content height changes, which could affect `ScrollBottom`'s auto-scroll. This is acceptable — if the user manually collapsed a phase, they're reviewing history, not watching the latest messages.

### Step 4: Add Gherkin scenarios to `features/brainstorm_idea_workflow.feature`

Append after the last existing scenario (line 123):

```gherkin
  Scenario: Manually expanded previous phase stays open during updates
    Given the session is in Phase 5 - Technical Concerns
    And Phase 3 - Task Description is collapsed
    When I expand Phase 3 by clicking its header
    And new activity occurs in the current phase
    Then Phase 3 should remain expanded

  Scenario: Manually collapsed current phase stays closed during updates
    Given the session is in Phase 5 - Technical Concerns
    And Phase 5 is expanded by default
    When I collapse Phase 5 by clicking its header
    And new activity occurs in the current phase
    Then Phase 5 should remain collapsed
```

### Step 5: Add tests to the brainstorm workflow test file

Add tests in `test/destila_web/live/brainstorm_idea_workflow_live_test.exs` tagged to the new scenarios.

These tests verify the server-side behavior: that re-renders don't forcefully change phase section state. Since LiveViewTest doesn't execute JavaScript hooks, the tests should verify:

1. The `<details>` elements have the correct `phx-hook=".PhaseToggle"` attribute
2. The `<details>` elements have stable `id` attributes matching the expected pattern
3. The server-side `open` attribute logic continues to work correctly (phases >= current are open, earlier ones are closed)

The actual toggle-preservation behavior is JavaScript-only and would need browser-level testing (e.g., Wallaby) to fully verify. The LiveView tests ensure the hook is wired correctly and the server defaults are sound.

```elixir
@tag feature: @feature, scenario: "Manually expanded previous phase stays open during updates"
test "phase sections have PhaseToggle hook for toggle state preservation", %{conn: conn} do
  project = create_project()
  ws = create_session_in_phase(5, project_id: project.id)
  {:ok, view, _html} = live(conn, "/sessions/#{ws.id}")

  # Phase 3 (< 5) should have open=false by default, with the hook attached
  refute has_element?(view, "details#phase-section-3[open]")
  assert has_element?(view, "details#phase-section-3[phx-hook='.PhaseToggle']")

  # Phase 5 (== current) should have open=true by default, with the hook attached
  assert has_element?(view, "details#phase-section-5[open]")
  assert has_element?(view, "details#phase-section-5[phx-hook='.PhaseToggle']")
end

@tag feature: @feature, scenario: "Manually collapsed current phase stays closed during updates"
test "phase sections retain server-computed open state after re-render", %{conn: conn} do
  project = create_project()
  ws = create_session_in_phase(5, project_id: project.id)
  {:ok, view, _html} = live(conn, "/sessions/#{ws.id}")

  # Verify initial state
  assert has_element?(view, "details#phase-section-5[open]")

  # Trigger a re-render (simulate PubSub update)
  send(view.pid, {:workflow_session_updated, Destila.Workflows.get_workflow_session!(ws.id)})

  # Server should still compute the same open states
  assert has_element?(view, "details#phase-section-5[open]")
  refute has_element?(view, "details#phase-section-3[open]")
end
```

### Step 6: Run `mix precommit`

Verify compilation, formatting, and all tests pass.

## Edge Cases

### Phase advance (e.g., phase 5 → 6)

When the current phase advances, the server's default changes: phase 5 was `open` (5 >= 5), and remains `open` (5 >= 6 is false... actually 5 < 6, so phase 5 would now be closed). Wait — re-reading the logic: `open={phase >= @phase_number}`. With `@phase_number = 5`, phases 5 and 6 are open. With `@phase_number = 6`, only phase 6 is open, and phase 5 closes.

So on phase advance from 5 → 6:
- Phase 5 changes from open → closed (server default)
- If user had manually collapsed phase 5 (override = closed), and now server also wants it closed → override is redundant → cleared in `updated()` ✓
- If user had manually expanded phase 3 (override = open), and server still wants it closed (3 < 6) → override persists → phase 3 stays open ✓

### Frequent `updated()` calls during streaming

When messages stream in, the phase component re-renders frequently. Each `updated()` call:
1. Reads the `open` attribute (fast DOM read)
2. Checks the `Map` (O(1) lookup)
3. Optionally sets/removes `open` (single DOM write)

This is minimal work per cycle. The `_restoring` flag prevents toggle event cascades. No flicker because the restoration happens synchronously before the browser paints.

### Multiple `<details>` elements

Each phase section gets its own hook instance with its own `_serverOpen` and `_restoring` state. The shared `userOverrides` map uses unique IDs (`phase-section-3`, `phase-section-5`, etc.), so there's no cross-contamination.

## Verification

1. `mix precommit` passes (compilation, formatting, tests)
2. Manual test: navigate to a session in phase 5, expand phase 3, send a message → phase 3 stays expanded after re-render
3. Manual test: collapse phase 5, wait for AI response → phase 5 stays collapsed
4. Manual test: advance from phase 5 to 6 → previously set overrides for phase 5 are cleaned up if they match the new server default
