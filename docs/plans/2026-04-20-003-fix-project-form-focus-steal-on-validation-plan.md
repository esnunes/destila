---
title: "fix: stop project form from stealing focus back to name during validation"
type: fix
status: active
date: 2026-04-20
---

# fix: stop project form from stealing focus back to name during validation

## Overview

Narrow the `FocusFirstError` LiveView hook so it no longer pulls focus back to the first invalid input while the user is actively typing in another field of the same form. After this change, a failed submit still auto-focuses the first error (today's desired behavior), but subsequent `phx-change` re-renders that leave the errors intact do not steal focus away from the input the user is currently editing.

## Problem Frame

On the project form (`DestilaWeb.ProjectFormLive`) the user hits Create with empty or insufficient fields, the LiveComponent returns `{:error, changeset}`, and errors are assigned onto the form (at minimum `:name` and `:location`). The template sets `aria-invalid="true"` on the `name`, `git_repo_url`, and `local_folder` inputs and re-renders. The `FocusFirstError` JS hook, attached via `phx-hook="FocusFirstError"` on the `<form>` element, runs its `updated()` callback and calls `el.focus()` on the first `[aria-invalid='true']` — which is the `name` input. That behavior is correct as the initial response to a failed submit.

The bug is that the same `updated()` callback fires on **every** subsequent DOM patch, including the `phx-change="validate"` callbacks the form emits as the user types. `handle_event("validate", ...)` only re-assigns the form params; it does **not** clear `@errors`. So every keystroke in `git_repo_url` (or `local_folder`, or `service_env_var`) re-renders with `aria-invalid="true"` still on `name`, the hook runs again, and focus jumps back to `name`. Typing becomes impossible in any field other than the one the auto-focus prefers.

The user-observable fix is: once the initial auto-focus has happened, let the user move to any other field and stay there while typing, even if errors remain on the form.

## Requirements Trace

- R1. After a failed submit on the project form, focus still lands on the first input with `aria-invalid="true"` (today's behavior, unchanged from the user's perspective on the first error render).
- R2. While the user is typing in any form input (`input`, `textarea`, `select`) inside the project form, subsequent LiveView DOM patches triggered by `phx-change="validate"` do not move focus away from that input, even when other inputs still have `aria-invalid="true"`.
- R3. The fix works for all instances of the `FocusFirstError` hook in the app (the hook is generic; today only `ProjectFormLive` attaches it, in both the standalone projects page and the inline drafts/workflow creation contexts).
- R4. The `ProjectFormLive` LiveComponent's `validate` and `save` handlers are not changed; no server-side coordination for focus is added.
- R5. A regression test documents the fixed behavior so the failure mode cannot silently return.
- R6. The `features/project_management.feature` Gherkin file gains a scenario (or scenario step) covering the focus-preservation invariant.

## Scope Boundaries

- **No change** to `Destila.Projects.Project` changeset or validators.
- **No change** to `DestilaWeb.ProjectFormLive.handle_event/3` (`validate` and `save` both remain untouched).
- **No change** to the form template markup: `aria-invalid` toggles, `phx-mounted={JS.focus()}` on the `name` input, the `phx-change="validate"` and `phx-submit="save"` event bindings, the error messages, and the error-styling classes stay exactly as they are.
- **No change** to the `ProjectComponents` wrapper, `ProjectsLive`, or the inline drafts/workflow creation flows. They consume the component unchanged.
- **No** introduction of a server-push event (`push_event "focus_first_error"`) or a new LiveView-to-hook channel. The fix is JS-local. (See *Alternative Approaches Considered* for why.)
- **No** refactor of the hook into a colocated JS hook or a rename. It stays at `FocusFirstError` in `assets/js/app.js` and registered under `Hooks`.
- **No** behavioral change to the three other hooks in `assets/js/app.js` (`ScrollBottom`, `AutoDismiss`) or to anything that depends on `phx-hook="FocusFirstError"` being attached only to the project form.

## Context & Research

### Relevant Code and Patterns

- `assets/js/app.js:36-42` — the `FocusFirstErrorHook` definition. `updated()` unconditionally focuses the first `[aria-invalid='true']` descendant. This is the single file the fix modifies for JS behavior.
- `assets/js/app.js:59-67` — the `Hooks` object that registers `FocusFirstError` for the LiveSocket. Unchanged by the fix; referenced here for orientation.
- `lib/destila_web/live/project_form_live.ex:79-86` — the `<form>` element carries `phx-hook="FocusFirstError"` with `id={"#{@id}-form"}`. This is the only attachment point in the app today.
- `lib/destila_web/live/project_form_live.ex:91-103` — the `name` input sets `aria-invalid={@errors[:name] && "true"}` and `phx-mounted={JS.focus()}`. The `phx-mounted={JS.focus()}` handles the initial focus on mount (new project card open); the hook handles refocus after a failed submit.
- `lib/destila_web/live/project_form_live.ex:120-131`, `:144-155`, `:199-210` — the `git_repo_url`, `local_folder`, and `service_env_var` inputs. These are the inputs the user is trying to type into when the focus steal occurs.
- `lib/destila_web/live/project_form_live.ex:31-33` — `handle_event("validate", ...)` only re-wraps the params; it does **not** clear `@errors`. This is the reason errors persist across keystrokes, which in turn is why the hook's `updated()` keeps triggering. The fix leaves this behavior alone and instead teaches the hook to respect the user's focus.
- `lib/destila_web/live/project_form_live.ex:35-62` — `handle_event("save", ...)` returns `{:error, changeset}` and assigns `@errors`. The hook's initial auto-focus happens on the re-render that follows this branch; that behavior must be preserved (R1).
- `lib/destila_web/components/project_components.ex` and `lib/destila_web/live/projects_live.ex` — callers of `ProjectFormLive`. No changes here; confirming they remain untouched.
- `test/destila_web/live/projects_live_test.exs:92-119` — the existing "Cannot create a project without a name" and "Cannot create a project without git URL or local folder" tests. The new regression test is added alongside these, in the same `describe "create project"` block, reusing the same fixtures and selectors.
- `test/destila_web/live/project_inline_creation_live_test.exs:86-115` — mirror tests for the inline-on-workflow-creation path. No test needs to be added here; the LiveComponent-level fix covers both surfaces, and the regression test at `projects_live_test.exs` is sufficient.
- `features/project_management.feature:45-50` — the `Cannot create a project without a name` scenario. The new Gherkin scenario for focus preservation goes immediately after this block, linked by a new `@tag scenario: ...` in the test file.

### Institutional Learnings

- From `docs/plans/2026-04-14-002-refactor-extract-project-form-live-component-plan.md` (the plan that introduced `ProjectFormLive` as a LiveComponent): the `FocusFirstError` hook was explicitly flagged as an item to verify in the LiveComponent context ("Whether the `FocusFirstError` hook on the form needs adjustment for the LiveComponent context"). The refactor plan deferred this to implementation, and implementation shipped the hook as-is. This bug is the deferred question surfacing: the hook's `updated()` contract is broken in any form that does client-side `phx-change="validate"` against persistent `@errors`.
- No entries in `docs/solutions/` exist today (grep confirmed). This fix should generate one after it lands (captured in *Documentation / Operational Notes* below).
- The project's CLAUDE.md forbids `<script>` tags in HEEx and steers all custom JS either into `assets/js/app.js` object-literal hooks or into colocated hook scripts. The existing `FocusFirstError` is an object-literal hook in `assets/js/app.js`; the fix stays in that file to match conventions.
- The test conventions in CLAUDE.md require `@tag feature: ..., scenario: ...` for every new test covering a Gherkin scenario, and require the feature file to be updated when new behavior is added. Unit 3 enforces both.

### External References

None. The fix is a narrowing of an existing DOM-lifecycle check; no external library documentation is needed. Standard DOM APIs in use: `Element.contains(node)`, `document.activeElement`, `Element.tagName`, and `Element.querySelector` — all baseline and already used by the existing hook.

## Key Technical Decisions

- **Fix in JS only, inside the existing `FocusFirstError` hook, not via a server-driven push_event.** The bug's root cause is that `updated()` is the wrong lifecycle for "first-error focus": it fires on every patch, not only on the patch that introduces errors. Narrowing `updated()` with an active-element check is a 3-line change that fixes every attachment point of the hook (present and future) and requires no coordination between the LiveComponent and the hook. The alternative (server-driven `push_event "focus_first_error"` from the `save` error branch, with a `handleEvent` listener in the hook) is correct, but introduces a second contract between the LiveComponent and the hook for a benefit the JS fix already delivers. Kept as explicit rejected alternative below rather than silently dropped.
- **Skip refocus when `document.activeElement` is an `INPUT`, `TEXTAREA`, or `SELECT` contained by the hook's root element.** This is the minimum condition that distinguishes "user is typing in this form" from "user just clicked Create and the submit button now holds focus" (button focus must not skip refocus — that case is R1). Using `tagName` avoids brittle checks against specific field ids, so new inputs added to the form (e.g., a future `worktree_root` field) inherit the correct behavior automatically.
- **Do not track internal state in the hook** (e.g., "have I already focused once?"). State-ful hooks are a larger surface area to reason about and mis-fire across LiveView navigations. The active-element check is stateless and sufficient.
- **Do not clear `@errors` in `handle_event("validate", ...)` as an alternative fix.** That would also prevent the hook from re-running since `aria-invalid` would drop off between the submit-render and the first keystroke. But it would change the user-facing behavior materially: the inline error text (`"can't be blank"`, `"please provide at least one"`) would flicker away as the user types and only reappear on the next `save`. The current error-persistence is a product choice (errors stay visible until fixed-and-resubmitted); this fix preserves it.
- **Do not restrict the hook to the project form specifically.** The hook is generic by design. Narrowing its `updated()` contract is a correctness improvement for any future form that attaches it, not a project-form-specific patch.

## Open Questions

### Resolved During Planning

- **Should the fix preserve focus when focus is on a non-input control inside the form, like a button?** No. The "click Create, see errors, get first-error focused" flow relies on the fact that after click the submit button holds focus, which is *not* an input. The check specifically targets `INPUT` / `TEXTAREA` / `SELECT` so button focus does not block the auto-focus. Explicitly verified in Unit 2's test scenarios.
- **Should `phx-mounted={JS.focus()}` on the `name` input be removed, since the hook now handles focus?** No. `phx-mounted` fires when the form first mounts (e.g., the user clicks the New Project button and the form card slides in). At that moment `@errors` is empty, so the hook's `querySelector` returns nothing and `updated()` is a no-op. `phx-mounted` and the hook cover disjoint states (initial mount vs. post-submit error render) and both are needed.
- **Does the hook need to handle the `destroyed()` lifecycle?** No. There is no per-instance state (no timers, no listeners beyond the implicit `updated()` callback) to clean up. Matches the existing shape of `ScrollBottomHook`.
- **Does `handle_event("validate", ...)` need to clear `@errors` as part of this fix?** No. See Key Technical Decisions above. The product choice is to keep errors visible until the next `save` succeeds, and this fix does not revisit that.
- **Should the regression test be at the LiveView level or at a JS / browser level?** LiveView level, via `render_submit` followed by `render_change` and assertions against the rendered HTML. The LiveView test cannot directly assert `document.activeElement`, but it **can** assert the invariant that actually matters at the server contract: the form rerenders on `validate` without re-setting any attribute that would re-fire the hook's focus logic (i.e., `aria-invalid` on `name` stays stable, `phx-mounted` is not re-emitted on the git URL input). A JS-level test (Wallaby/browser) is not justified for a 3-line hook change in a project that does not otherwise run browser tests for this surface.
- **Does the plan need to cover the inline project-creation path (`project_inline_creation_live_test.exs`)?** No separate test addition. The hook lives on the `<form>` element rendered by `ProjectFormLive`, which is shared between `ProjectsLive` and the inline-on-workflow-creation callers. One LiveView-level regression test at `projects_live_test.exs` plus one new Gherkin scenario is enough coverage for R5/R6.

### Deferred to Implementation

- **Exact DOM-check idiom for `activeElement` inside Shadow DOM or iframe edge cases.** Not relevant to this codebase today (no shadow DOM, no iframe forms), but the implementer may choose `this.el.contains(document.activeElement)` or `this.el === document.activeElement.closest("form")` — whichever reads more clearly. Either works; the deferred choice is stylistic.
- **Whether to also log a short rationale comment in the hook.** The CLAUDE.md guidelines discourage comments that restate what code does, but this particular check's *why* (the `updated()` on `phx-change` re-entry problem) is non-obvious enough that a one-line comment may earn its keep. Implementer's call during PR review.

## Implementation Units

- [ ] **Unit 1: Narrow the `FocusFirstError` hook's `updated()` to preserve user focus in form inputs**

**Goal:** Teach the `FocusFirstError` hook to skip its focus-steal when the user is already typing into an `INPUT`, `TEXTAREA`, or `SELECT` that lives inside the hook's root element. Leave the initial "click Create, see errors, auto-focus first invalid" path untouched.

**Requirements:** R1, R2, R3

**Dependencies:** None

**Files:**
- Modify: `assets/js/app.js`

**Approach:**
- In the existing `FocusFirstErrorHook.updated()` function in `assets/js/app.js`, add an early-return guard before the `querySelector("[aria-invalid='true']")` call that checks whether `document.activeElement` is both (a) contained by `this.el` and (b) an `INPUT`, `TEXTAREA`, or `SELECT`. If both are true, return without moving focus.
- Leave the rest of the hook — the `querySelector` selector, the `requestAnimationFrame(() => el.focus())` call, the `if (!el) return` nil-guard — exactly as-is.
- Do **not** change the registration in the `Hooks` object, the `LiveSocket` constructor call, or any other part of `assets/js/app.js`.

**Technical design:** *(directional guidance; implementer chooses the exact idiom — see Deferred to Implementation)*

```
updated():
  active = document.activeElement
  if active is inside this.el AND active.tagName in {INPUT, TEXTAREA, SELECT}:
    return                     # user is typing; do not steal focus

  target = this.el.querySelector("[aria-invalid='true']")
  if target is null:
    return                     # nothing to focus
  requestAnimationFrame(() => target.focus())
```

**Patterns to follow:**
- `assets/js/app.js:31-34` — `ScrollBottomHook`'s terse `updated()` style (single guard, one action, no state).
- `assets/js/app.js:44-57` — `AutoDismissHook` shows the project's convention for slightly richer hooks with guard-clause structure.

**Test scenarios:**
- *(All behavioral scenarios for this unit are asserted in Unit 2's LiveView tests; this unit produces no JS-level tests since the project does not run Jest / browser JS tests for hooks.)*
- Happy path: with the form freshly mounted and no errors set, the hook's `updated()` runs and is a no-op because `querySelector` returns null. Verified indirectly by the existing "creates a project with git URL" test continuing to pass.
- Happy path (initial error auto-focus, R1): after a failed submit where the submit button (`<button type="submit">`) holds focus, `active.tagName === "BUTTON"`, the input guard does not short-circuit, and the hook focuses the first `[aria-invalid='true']` input — preserving the user-observable behavior that already exists today. Verified at the LiveView level in Unit 2 via DOM-level assertions on `aria-invalid` placement and by the fact that the existing "shows error when name is empty" test continues to pass.
- Edge case (the bug, R2): after the initial error focus, when focus is on any input inside the form (`name`, `git_repo_url`, `local_folder`, `setup_command`, `run_command`, or `service_env_var`) and a `phx-change="validate"` patch arrives, the hook returns early and no focus movement occurs. Verified at the LiveView level in Unit 2 by asserting that a `render_change` call that simulates typing into `git_repo_url` does not reset `@errors` or re-apply `phx-mounted` focus commands.
- Edge case: active element is outside the form entirely (e.g., user alt-tabbed, then the LiveView pushed an unrelated patch). `this.el.contains(document.activeElement)` is false, the input guard does not short-circuit, and the hook focuses the first invalid input. This matches current behavior (no regression for this path).

**Verification:**
- `assets/js/app.js` still exports and registers `FocusFirstError` under the same name in the same place.
- The hook's `updated()` is the only function touched; `mounted()` is not added and no other hook is modified.
- `mix assets.build` (or whatever the project's esbuild invocation is via `mix precommit`) produces no new JS warnings.

- [ ] **Unit 2: Add a LiveView regression test for focus-preservation during project-form validation**

**Goal:** Document the fixed behavior with a test that fails on the pre-fix code and passes after Unit 1. The test operates at the server contract the hook depends on, not at the JS level.

**Requirements:** R5

**Dependencies:** Unit 1

**Files:**
- Modify: `test/destila_web/live/projects_live_test.exs`

**Approach:**
- In the `describe "create project"` block (around `test/destila_web/live/projects_live_test.exs:40-120`), add a new test tagged `@tag feature: @feature, scenario: "Typing in git repository URL preserves focus after validation errors"` (matching the Gherkin scenario added in Unit 3).
- The test flow:
  1. `{:ok, view, _html} = live(conn, ~p"/projects")`.
  2. Click `#new-project-btn` to open the form card, assert `#create-project-card` is present.
  3. `render_submit` the form with `%{"name" => ""}` (empty) and assert the response contains the `"can't be blank"` and `"provide at least one"` error strings and that the `name` input now carries `aria-invalid="true"` (assert via `has_element?(view, "input[name=name][aria-invalid='true']")`).
  4. `render_change` the form with new params that include the now-typed git URL (e.g., `%{"name" => "", "git_repo_url" => "h"}` for one keystroke, or the full `"https://github.com/test/repo"` — a single representative value is sufficient).
  5. Assert the rendered HTML after the `render_change`: the `git_repo_url` input's `value` attribute reflects the typed value (`assert has_element?(view, "input[name=git_repo_url][value='https://github.com/test/repo']")`), confirming the server round-trip worked. Assert that `aria-invalid="true"` is still on the `name` input (errors were not cleared by `validate`). Assert that no `phx-mounted` attribute is present on the `git_repo_url` input (confirming no server-side attempt to re-focus via JS command).
  6. *(Focus-preservation itself cannot be asserted from `Phoenix.LiveViewTest` because it does not run the hook's JS `updated()` callback. The regression value of this test is locking in the preconditions the hook relies on: `aria-invalid` persistence on `name` across `validate`, and the absence of server-side focus commands that would override the hook's guard.)* A short ExUnit doc comment on the test explaining this scope keeps the next maintainer from expecting a runtime focus assertion.
- Do not add a mirror test in `project_inline_creation_live_test.exs`. The hook and LiveComponent are shared; one test at the canonical surface is sufficient and matches the project's existing coverage style for `ProjectFormLive`.

**Patterns to follow:**
- `test/destila_web/live/projects_live_test.exs:105-119` — the existing "Cannot create a project without a name" test is the closest structural template: same `live/2` bootstrap, same `render_click`, same `render_submit`, same assertion style on rendered HTML.
- `test/destila_web/live/projects_live_test.exs:40-58` — the "creates a project with git URL" test shows the full `#project-form-create-form` id and the `render_submit` form param shape.

**Test scenarios:**
- *(The test added in this unit is itself the scenario. It covers:)*
- Edge case / regression: submit empty → errors appear on `name` → simulate typing into `git_repo_url` via `render_change` → errors still visible, git URL value round-trips to the server, and no server-emitted JS focus command appears on the URL input. This documents the server contract Unit 1 relies on.

**Verification:**
- `mix test test/destila_web/live/projects_live_test.exs` passes locally.
- The new test is linked to the new Gherkin scenario via `@tag`.
- Running the test against pre-Unit-1 code is not required, but the test's assertions on `aria-invalid` persistence and `value` round-trip hold under pre-fix code too (the JS-side focus-steal cannot be asserted here, as noted above). The test's purpose is lock-in of the server preconditions, not reproduction of the JS-level bug.

- [ ] **Unit 3: Update the `project_management.feature` Gherkin file**

**Goal:** Add a scenario describing the focus-preservation invariant so the feature file remains the behavioral source of truth for the project form.

**Requirements:** R6

**Dependencies:** Unit 2

**Files:**
- Modify: `features/project_management.feature`

**Approach:**
- Insert a new scenario immediately after the existing `Scenario: Cannot create a project without a name` block (i.e., after line 50 in the current file). Name it `Scenario: Typing in git repository URL preserves focus after validation errors`. Steps should read, at roughly this specificity:
  - `When I navigate to the projects page`
  - `And I click "New Project"`
  - `And I submit the form without filling in any fields`
  - `Then I should see an error indicating a name is required`
  - `When I type a git repository URL in the git repository URL field`
  - `Then the git repository URL field should remain focused while I type`
- Do not alter any other scenario in the file. The new scenario is additive.
- Confirm the new scenario's name matches the string passed to `@tag scenario:` in Unit 2. Running `mix test --only "scenario:Typing in git repository URL preserves focus after validation errors"` after Units 1-3 should select the Unit 2 test.

**Patterns to follow:**
- `features/project_management.feature:45-50` — the immediately-preceding "Cannot create a project without a name" scenario for stylistic consistency (step verbs, capitalization, absence of trailing punctuation).
- `features/session_deletion.feature` and `docs/plans/2026-04-20-002-fix-always-redirect-to-crafting-after-delete-plan.md` — recent precedent for adding a fix-scoped scenario alongside a fix-scoped test.

**Test scenarios:**
- *Test expectation: none — this is a documentation file. Linkage is verified by running `mix test --only feature:project_management` after Unit 2, which should match every scenario in the feature file to at least one test.*

**Verification:**
- `mix test --only feature:project_management` is green.
- Grepping `features/project_management.feature` for the new scenario name returns exactly one match.
- The new scenario appears exactly once in the file and directly follows `Scenario: Cannot create a project without a name`.

- [ ] **Unit 4: Pre-commit hygiene and manual walkthrough**

**Goal:** Run the project's pre-commit alias and manually verify the fix in the browser for both form surfaces (`/projects` and the inline drafts/workflow creation path).

**Requirements:** All

**Dependencies:** Units 1-3

**Files:** None (verification only)

**Approach:**
- Run `mix precommit`. Address any formatter, compiler, Credo, or test failures.
- Start the server per `CLAUDE.md` (`elixir --sname destila -S mix phx.server`).
- Manual walkthrough, Surface A (standalone projects page):
  1. Navigate to `/projects`, click New Project.
  2. Click Create without filling anything. Confirm name-required and location-required errors appear, and that focus lands on the `name` input (R1 preserved).
  3. Tab into `git_repo_url` and begin typing `https://github.com/foo/bar`. Confirm focus stays in the URL field and every character lands in it (R2 fixed).
  4. Fix the errors (type a name; the URL is already filled) and click Create. Confirm the project is created normally.
- Manual walkthrough, Surface B (inline on workflow creation):
  1. Navigate to `/workflows/brainstorm_idea` (matching the inline test path).
  2. Click the inline "Create new project" affordance (`#create-new-project-btn`).
  3. Submit empty; confirm the same error + focus behavior as Surface A.
  4. Type into the URL field; confirm focus preservation.
- If either walkthrough fails, the fix is incomplete; revisit Unit 1 before shipping.

**Test scenarios:**
- *Test expectation: none — verification-only step.*

**Verification:**
- `mix precommit` exits 0.
- Both manual walkthroughs (Surface A and Surface B) show the user can type uninterrupted in `git_repo_url` after a failed submit.
- The initial post-submit auto-focus on `name` still works on both surfaces.

## System-Wide Impact

- **Interaction graph:**
  - `FocusFirstErrorHook.updated()` (`assets/js/app.js`) — the single JS surface that changes. Its contract for *when* it moves focus is narrowed; its contract for *where* it moves focus (first `[aria-invalid='true']` descendant) is unchanged.
  - `DestilaWeb.ProjectFormLive` form template — unchanged; continues to attach `phx-hook="FocusFirstError"` and toggle `aria-invalid`.
  - `DestilaWeb.ProjectsLive`, `DestilaWeb.ProjectComponents`, and the inline drafts/workflow creation path that embeds `ProjectFormLive` — all unchanged; all inherit the fix through the shared hook.
  - No other LiveView or component in the app attaches `phx-hook="FocusFirstError"` today (confirmed via grep). Any future attachment inherits the fixed behavior.
- **Error propagation:** Unchanged. The LiveComponent's `handle_event("save", ...)` error branch still assigns `@errors` and re-renders; the LiveComponent's `handle_event("validate", ...)` still re-wraps params without clearing `@errors`.
- **State lifecycle risks:**
  - None. The hook remains stateless. No timers, no added event listeners, no `destroyed()` cleanup needed.
  - `document.activeElement` is reliably populated by the browser during DOM patches and after focus-returning operations; no race with `requestAnimationFrame`.
- **API surface parity:** No external API changes. The JS hook's public shape (`FocusFirstError` in `assets/js/app.js`, attached via `phx-hook="FocusFirstError"`) stays identical.
- **Integration coverage:** Unit 2's LiveView test covers the server-contract preconditions. Unit 4's manual walkthrough covers the JS-runtime behavior that LiveView tests cannot reproduce (actual focus movement in a live browser). Together they cover the server/client seam this fix lives on.
- **Unchanged invariants:**
  - `Project` changeset, validators, error shape.
  - `ProjectFormLive`'s `validate` / `save` event handlers and their assigns (`@form`, `@errors`).
  - `aria-invalid` semantics on each input (still reflects `@errors`).
  - The `phx-mounted={JS.focus()}` on the `name` input for initial-mount focus.
  - The `#project-form-...-form` id scheme used by tests and by the LiveComponent.
  - The `FocusFirstError` hook's selector (`[aria-invalid='true']`) and focus mechanism (`requestAnimationFrame` + `.focus()`).

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| A future form attaches `FocusFirstError` and expects focus-steal on *every* update, not just the first. | The hook's name and the new guard both communicate "focus first error only when the user is not already typing"; any future consumer should design around that. If a genuinely different need surfaces, introduce a second hook rather than reverting this one. |
| `document.activeElement` returns `<body>` in some edge case (e.g., after a programmatic blur), causing the guard to incorrectly allow the focus-steal. | Acceptable. In that case the hook's behavior matches its pre-fix behavior (focus lands on the first invalid input). No regression relative to today. |
| The manual walkthrough in Unit 4 is skipped and a JS-only regression slips in. | Unit 4 explicitly lists both surfaces; PR description should restate that the manual verification ran and showed the intended behavior. The test in Unit 2 additionally locks in the server preconditions the hook depends on. |
| A test in `project_inline_creation_live_test.exs` or another caller of `ProjectFormLive` implicitly depended on focus-steal behavior and now fails. | `mix test` in Unit 4 covers this. No such test exists today (the existing tests only assert error strings render; none assert on focus movement), but `mix precommit` is the backstop. |

## Alternative Approaches Considered

- **Server-driven `push_event "focus_first_error"` on the `save` error branch, with a `handleEvent` listener in the hook replacing `updated()`.** Rejected. It is the most semantically precise fix — "focus first error exactly when save fails, never otherwise" — but it expands the contract between `ProjectFormLive` and the hook (the LiveComponent becomes responsible for emitting the event) and requires every future consumer of the hook to also emit it. The JS-only guard delivers the same user-observable behavior with no server change and no new contract. If the hook later gains requirements the active-element guard cannot express (e.g., focus-first-error after a background broadcast updates the form), revisit this alternative.
- **Clear `@errors` in `handle_event("validate", ...)`.** Rejected. It would drop `aria-invalid` between the post-submit render and the first keystroke, which side-effects the hook into not re-running. But it also changes the product's error-visibility behavior (errors would disappear as the user types, then reappear on the next submit). The current error-persistence is intentional; the fix should not silently revoke it.
- **Track a "has-focused-once" boolean inside the hook.** Rejected. Adds per-instance state that must be reset across LiveView navigations and remounts. The stateless active-element guard handles the same cases with less surface area.
- **Replace `updated()` with `mounted()` and rely on LiveView re-mounting the form on error.** Rejected. LiveView does **not** re-mount the form on phx-change; it patches it. `mounted()` would fire only once per form instance, which is too narrow (it would miss the post-submit error focus entirely, since mount happens before any submit).
- **Add `phx-update="ignore"` to the form.** Rejected. The form's inputs need to be patched by LiveView for `value` round-trips and for `aria-invalid` toggling. `phx-update="ignore"` would break both.

## Documentation / Operational Notes

- No documentation updates needed beyond the PR description. The PR should link this plan, describe the user-visible symptom ("typing in git URL after a failed submit snapped focus back to Name"), and reference Unit 4's manual-walkthrough outcome.
- After the fix lands, add a short entry under `docs/solutions/` titled "Phoenix LiveView hook `updated()` steals focus during `phx-change`" capturing the root cause, the fix, and the active-element-guard pattern. The CLAUDE.md institutional-learnings workflow expects this, and the next form that reaches for `FocusFirstError` should find the note.
- No rollout flag, no migration, no monitoring changes. The fix is a pure JS narrowing.

## Sources & References

- **Origin defect report:** user prompt describing focus snapping back to the project name field while typing in the git repository URL after a failed empty-submit.
- **Related code:** `assets/js/app.js:36-42` — the `FocusFirstErrorHook` being modified.
- **Related code:** `lib/destila_web/live/project_form_live.ex` — the sole current attachment point for the hook; contains the form template and the `validate` / `save` handlers whose error-persistence behavior is being preserved.
- **Related code:** `lib/destila_web/components/project_components.ex`, `lib/destila_web/live/projects_live.ex` — embedding surfaces that inherit the fix unchanged.
- **Related test:** `test/destila_web/live/projects_live_test.exs` — location of the new regression test in Unit 2.
- **Related test:** `test/destila_web/live/project_inline_creation_live_test.exs` — mirror surface; verified to pass unchanged.
- **Related feature:** `features/project_management.feature` — updated in Unit 3 with the focus-preservation scenario.
- **Related plan (prior art):** `docs/plans/2026-04-14-002-refactor-extract-project-form-live-component-plan.md` — introduced `ProjectFormLive` as a LiveComponent and explicitly deferred the hook-in-LiveComponent question. This plan resolves that deferred question.
- **Related plan (format template):** `docs/plans/2026-04-20-002-fix-always-redirect-to-crafting-after-delete-plan.md` — used as a structural template for a fix-scoped plan with LiveView test + Gherkin update + manual walkthrough.
