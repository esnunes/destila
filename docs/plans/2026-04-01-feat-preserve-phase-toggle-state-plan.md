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

### Step 1: Wire the hook to `<details>` elements in the template

In `ai_conversation_phase.ex`, modify the `<details>` element (line 218) to add `phx-hook` and a unique `id`.

**Current code (lines 218-221):**
```heex
<details
  class={["phase-section", phase == elem(hd(@phase_groups), 0) && "first-phase"]}
  open={phase >= @phase_number}
>
```

**Replace with:**
```heex
<details
  id={"phase-section-#{phase}"}
  phx-hook=".PhaseToggle"
  class={["phase-section", phase == elem(hd(@phase_groups), 0) && "first-phase"]}
  open={phase >= @phase_number}
>
```

Notes:
- `id` is required for `phx-hook` (LiveView enforces this)
- The id format `phase-section-{phase}` is stable across re-renders since phase numbers don't change
- `phx-update="ignore"` is **NOT** used here — the hook needs LiveView to continue patching the DOM so it can detect server-side changes and selectively override them
- The `<details>` elements are inside a `for` comprehension (`<%= for {phase, group} <- @phase_groups do %>` on line 217), so each iteration gets its own unique id

### Step 2: Add the `.PhaseToggle` colocated hook `<script>` tag

Place the `<script :type={Phoenix.LiveView.ColocatedHook} name=".PhaseToggle">` block inside the `~H"""..."""` sigil, just before the closing `</div>` on line 325. This follows the same pattern as `.PromptCard` in `chat_components.ex:136-217` where the script tag is placed at the end of the template, inside the sigil but outside the HTML content that uses the hook.

**Important:** The `<script>` tag must be placed **outside** the `for` comprehension (which ends at line 244 with `<% end %>`). Placing it inside the loop would create duplicate script tags per phase section, which is invalid for colocated hooks.

**Insert before line 325 (`</div>`):**

```heex
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhaseToggle">
      // Module-level map: element ID → boolean (user's desired open state).
      // Shared across all hook instances since each <details> has a unique id.
      const userOverrides = new Map();

      export default {
        mounted() {
          // Snapshot what the server initially set for this element
          this._serverOpen = this.el.hasAttribute("open");
          this._restoring = false;

          // The native "toggle" event fires when <details> open state changes,
          // whether by user click or programmatic attribute change.
          this.el.addEventListener("toggle", () => {
            // Skip toggles caused by our own restoration in updated()
            if (this._restoring) return;

            const isOpen = this.el.hasAttribute("open");

            if (isOpen !== this._serverOpen) {
              // User toggled away from server default — record override
              userOverrides.set(this.el.id, isOpen);
            } else {
              // User toggled back to match server — clear override
              userOverrides.delete(this.el.id);
            }
          });
        },

        updated() {
          // After LiveView patches the DOM, capture what the server wants.
          // This MUST happen before any restoration so _serverOpen always
          // reflects the server's intent, not our override.
          this._serverOpen = this.el.hasAttribute("open");

          if (!userOverrides.has(this.el.id)) return;

          const desired = userOverrides.get(this.el.id);

          // If the server's new default matches the user's preference
          // (e.g. after phase advance), the override is redundant — clear it
          if (desired === this._serverOpen) {
            userOverrides.delete(this.el.id);
            return;
          }

          // Restore the user's preference, suppressing the toggle event
          this._restoring = true;
          if (desired) {
            this.el.setAttribute("open", "");
          } else {
            this.el.removeAttribute("open");
          }
          // The toggle event fires asynchronously after attribute change.
          // Use requestAnimationFrame to clear the flag after it fires.
          requestAnimationFrame(() => { this._restoring = false; });
        },

        destroyed() {
          userOverrides.delete(this.el.id);
        }
      }
    </script>
```

### Step 3: Verify `ScrollBottom` hook compatibility

The `ScrollBottom` hook (defined in `assets/js/app.js:28-31`) lives on `#chat-messages` (the scrollable container wrapping all phase sections, line 201). The `.PhaseToggle` hook lives on individual `<details>` elements inside that container. They operate on different elements and don't interfere:

- `ScrollBottom.updated()` sets `this.el.scrollTop = this.el.scrollHeight` on the `#chat-messages` div
- `.PhaseToggle.updated()` sets/removes the `open` attribute on `<details>` children

No changes needed to `ScrollBottom`. When `.PhaseToggle` restores a collapsed state, the content height changes. The `ScrollBottom` hook will still auto-scroll on its next `updated()` call. This is acceptable — if the user manually collapsed a phase, they're reviewing history, not watching the latest messages.

### Step 4: Add Gherkin scenarios to `features/brainstorm_idea_workflow.feature`

Append after the last existing scenario ("Answer AI with a multi-question form", ending at line 123):

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

Since LiveViewTest doesn't execute JavaScript hooks, the tests verify:
1. The `<details>` elements have the correct `phx-hook=".PhaseToggle"` attribute wired
2. The `<details>` elements have stable `id` attributes matching the expected pattern (`phase-section-{N}`)
3. The server-side `open` attribute default logic continues to work correctly (phases >= current are open, earlier ones are closed)
4. Re-renders preserve the server-computed defaults (the JS hook handles user overrides)

The actual toggle-preservation behavior is JavaScript-only and requires manual browser testing to fully verify.

**Test helper note:** The existing `create_session_in_phase/2` helper (line 39) creates messages in phases 3 and `phase` (the target phase). When creating a session in phase 5, it will have messages in phases 3 and 5, so `@phase_groups` will include entries for both phases. The helper sets `project_id: nil` by default. Since the test needs to navigate to `/sessions/:id` and the route requires a persisted session, but NOT a real project, passing `project_id: nil` from the existing helper is fine.

```elixir
@tag feature: @feature, scenario: "Manually expanded previous phase stays open during updates"
test "phase sections have PhaseToggle hook wired with correct IDs", %{conn: conn} do
  ws = create_session_in_phase(5)
  {:ok, view, _html} = live(conn, "/sessions/#{ws.id}")

  # Phase 3 (< 5) should be collapsed by default, with the hook attached
  assert has_element?(view, "details#phase-section-3[phx-hook='.PhaseToggle']")
  refute has_element?(view, "details#phase-section-3[open]")

  # Phase 5 (== current) should be open by default, with the hook attached
  assert has_element?(view, "details#phase-section-5[phx-hook='.PhaseToggle']")
  assert has_element?(view, "details#phase-section-5[open]")
end

@tag feature: @feature, scenario: "Manually collapsed current phase stays closed during updates"
test "server re-render preserves default open states without JS hook", %{conn: conn} do
  ws = create_session_in_phase(5)
  {:ok, view, _html} = live(conn, "/sessions/#{ws.id}")

  # Verify initial defaults
  assert has_element?(view, "details#phase-section-5[open]")
  refute has_element?(view, "details#phase-section-3[open]")

  # Simulate a PubSub-driven re-render (e.g., metadata update)
  send(view.pid, {:metadata_updated, ws.id})

  # Server should recompute the same open states
  assert has_element?(view, "details#phase-section-5[open]")
  refute has_element?(view, "details#phase-section-3[open]")
end
```

**Why `{:metadata_updated, ws.id}` instead of `{:workflow_session_updated, ws}`:** The `workflow_session_updated` handler in `WorkflowRunnerLive` (line 272) reloads the session and re-assigns shared state, which triggers the phase component's `update/2`. The `metadata_updated` handler (line 295) does the same via `assign(:metadata, ...)`. Both cause the phase component to re-render. Using `metadata_updated` is simpler because it only needs the session ID, avoiding the need to construct a full `workflow_session` struct.

### Step 6: Run `mix precommit`

Verify compilation, formatting, and all tests pass.

## How the `open` attribute logic works

The template uses `open={phase >= @phase_number}` where:
- `phase` is the phase number of each `<details>` section (from `@phase_groups`)
- `@phase_number` is the current active phase

This means **only the current phase is open** (where `phase == @phase_number`). Earlier phases (`phase < @phase_number`) are collapsed. There are no future phases rendered because `phase_groups/2` only includes phases that have messages or the current phase.

**Example with `@phase_number = 5` and messages in phases 3, 4, 5:**
- Phase 3: `3 >= 5` → `false` → collapsed
- Phase 4: `4 >= 5` → `false` → collapsed
- Phase 5: `5 >= 5` → `true` → **open**

## Edge Cases

### Phase advance (e.g., phase 5 → 6)

On phase advance from 5 → 6, the AiConversationPhase component is re-mounted (the parent `WorkflowRunnerLive` renders a new `live_component` with `id={"phase-#{current_phase}"}`, so the component ID changes from `phase-5` to `phase-6`). This means:

- All existing hook instances are destroyed (calling `destroyed()`, which cleans up `userOverrides`)
- New hook instances are mounted for the new phase's `<details>` elements
- All overrides from the previous phase are naturally cleared

This is the desired behavior — when the phase advances, a fresh view is appropriate.

**However**, if the component is NOT re-mounted (e.g., if the parent just updates assigns without changing the component ID), then:
- Phase 5: server changes from `open` (5 >= 5) to `closed` (5 >= 6 = false)
- If user had override `closed` for phase 5, it now matches server → override cleared ✓
- If user had override `open` for phase 3, server still wants `closed` (3 >= 6 = false) → override persists ✓

### Frequent `updated()` calls during streaming

When messages stream in (`{:ai_stream_chunk, chunk}` handler in `WorkflowRunnerLive`, line 303), the parent re-assigns `@streaming_chunks`, which triggers the phase component's `update/2`, which re-renders the template. This happens frequently during AI responses.

Each `updated()` call in the hook:
1. Reads the `open` attribute — fast DOM property check
2. Checks the `Map` — O(1) lookup
3. Optionally sets/removes `open` — single DOM write

This is minimal work per cycle. The `_restoring` flag prevents toggle event cascades. No visual flicker because the restoration happens synchronously before the browser paints the next frame.

### The `toggle` event timing

The HTML spec says the `toggle` event fires asynchronously (it is dispatched as a task, not synchronously during attribute mutation). This means:

1. In `updated()`, we set `this._restoring = true`
2. We modify the `open` attribute
3. The `toggle` event is queued (not fired yet)
4. We schedule `requestAnimationFrame(() => { this._restoring = false; })`
5. The microtask/macrotask queue runs: `toggle` fires → handler checks `_restoring` → it's still `true` → skipped ✓
6. Next animation frame: `_restoring = false`

This ordering is safe because `requestAnimationFrame` callbacks run after event handlers for the same frame.

### Multiple `<details>` elements

Each phase section gets its own hook instance with its own `_serverOpen` and `_restoring` instance state. The shared `userOverrides` map uses unique IDs (`phase-section-3`, `phase-section-5`, etc.), so there's no cross-contamination.

## Verification

1. `mix precommit` passes (compilation, formatting, tests)
2. Manual test: navigate to a session in phase 5, expand phase 3, send a message → phase 3 stays expanded after re-render
3. Manual test: collapse phase 5, wait for AI response → phase 5 stays collapsed
4. Manual test: advance from phase 5 to 6 → view resets cleanly with fresh toggle states
5. Manual test: rapidly send messages while a phase is collapsed → no flicker or jank
