---
title: Add per-project mise auto-trust on worktree creation
type: feat
status: completed
date: 2026-04-22
---

# Add per-project mise auto-trust on worktree creation

## Overview

Introduce an opt-in per-project boolean flag `mise_auto_trust` (defaults to
`false`). When enabled, the worktree-preparation worker runs
`mise trust -y` inside the newly created worktree **before** the existing
`setup_command` runs, so setup can rely on a trusted mise configuration.

This is the full scope of "native mise support" for now. It does **not**
add `mise install`, does not wrap commands with `mise exec`, and does not
auto-detect mise config files. The flag alone drives the behavior.

## Problem Frame

Projects that use [mise](https://mise.jdx.dev) for tool-version management
require each new working directory to be trusted before mise will load its
configuration. Because Destila creates a fresh git worktree for every
workflow session under `.claude/worktrees/<session_id>`, that worktree is
always untrusted from mise's perspective, and any `setup_command` that
depends on mise-installed tools fails on first run unless the user manually
runs `mise trust` inside the worktree.

Giving projects a per-project opt-in flag lets Destila run `mise trust -y`
in the new worktree immediately after creation, so the subsequent
`setup_command` can use mise-managed binaries without manual intervention.

## Requirements Trace

- **R1.** Projects gain a persisted `mise_auto_trust` boolean flag that
  defaults to `false` for new and existing projects.
- **R2.** When `mise_auto_trust` is `true`, `mise trust -y` runs inside the
  newly created worktree before `setup_command` is dispatched to tmux.
- **R3.** When `mise_auto_trust` is `false`, the worker never invokes
  `mise`, and the worktree lifecycle is identical to today.
- **R4.** `mise trust -y` runs regardless of whether `setup_command` is
  blank — the two features are independent.
- **R5.** `mise trust -y` runs regardless of whether the worktree actually
  contains a `.mise.toml`, `mise.toml`, or `.tool-versions` file — no
  file-presence gating is performed.
- **R6.** A missing `mise` binary (`ErlangError :enoent`), non-zero exit,
  or any other raised error is logged at warning level and does not block
  worktree readiness or the subsequent `setup_command`.
- **R7.** `SessionProcess.worktree_ready/1` is always called regardless of
  mise or setup-command outcomes.
- **R8.** The project create/edit form exposes a checkbox for the new flag;
  the projects list card surfaces the enabled state.
- **R9.** Gherkin coverage exists for both the worker behavior
  (`features/mise_auto_trust.feature`) and the form/card UX additions in
  `features/project_management.feature`, and every test linked to those
  scenarios carries `@tag feature: "...", scenario: "..."`.

## Scope Boundaries

- **Not** implementing `mise install` — only `mise trust -y`.
- **Not** wrapping the existing `setup_command` or `run_command` with
  `mise exec`.
- **Not** auto-detecting mise config files to implicitly turn the flag on.
- **Not** changing the tmux service-window path for `setup_command` — mise
  trust uses a direct `System.cmd/3`, not the tmux channel.
- **Not** exposing the raw `mise trust` output in the UI; failures are
  logged server-side only.
- **Not** validating the host for the presence of a `mise` binary at
  project-save time — validation happens implicitly at worker execution.

## Context & Research

### Relevant Code and Patterns

- `lib/destila/projects/project.ex` — schema and changeset; add the new
  boolean to both the `schema` block and the `cast/3` allow-list. The
  existing `setup_command` field (added in migration
  `20260416000000_add_setup_command_to_projects`) is the closest template.
- `lib/destila/projects.ex` — `create_project/1` and `update_project/2`
  already delegate all attribute handling to `Project.changeset/2`, so no
  changes are needed in the context once the changeset is updated.
- `lib/destila/workers/prepare_workflow_session.ex` —
  `run_post_worktree_setup/3` is the integration point. The new mise step
  must run **before** the existing `setup_command` branch and must run even
  when `setup_command` is blank.
- `lib/destila/git.ex` — existing `System.cmd/3` usage in the same worker's
  upstream path (e.g., `Git.pull/1`) is the template for invoking external
  binaries with `stderr_to_stdout: true` and pattern-matching on exit
  status. Note: `Git.pull/1` does not wrap the call in `try/rescue`, so a
  missing binary would raise — for mise we want to rescue because the
  absence of mise on the host is a normal, non-blocking condition.
- `lib/destila_web/live/project_form_live.ex` — the `to_form/1` map, the
  `save` event's `attrs` map, and the `render/1` HEEx template all need
  the new field. The form currently uses plain `<input>` elements wrapped
  in `<fieldset class="fieldset">`, so the new checkbox should follow the
  same structural pattern (a fieldset containing the checkbox + label) and
  live inside the existing "Service" grouping, near the setup-command
  field.
- `lib/destila_web/live/projects_live.ex` — the display half of each card
  (the `:if={@editing_project_id != project.id}` branch) is where a small
  "auto-trust mise" badge/row should be rendered when the flag is on. The
  existing conditional rows (setup_command, run_command, etc.) follow the
  `<span :if={project.setup_command}>` pattern.
- `lib/destila_web/components/project_components.ex` — the inline create
  form is rendered via `DestilaWeb.ProjectFormLive`, so no changes here
  for form fields. Only revisit if a summary of the flag is desired in the
  selection UI (out of scope).
- `test/destila/workers/prepare_workflow_session_test.exs` — uses `Mimic`
  with `setup :set_mimic_from_context` and `stub(Tmux, ...)`. The same
  pattern applies to stubbing `System.cmd/3`. `test_helper.exs` must add
  `Mimic.copy(System)` so `System.cmd/3` becomes stubbable.
- `test/destila_web/live/projects_live_test.exs` — existing
  `setup_command` creation/edit tests (lines 281-365) are the direct
  template for the new form and card tests.

### Institutional Learnings

No prior entries in `docs/solutions/` for mise integration or
`System.cmd/3` stubbing with Mimic at the time of planning. The closest
precedents are:

- `docs/plans/2026-04-16-002-feat-project-setup-command-plan.md` — the
  original `setup_command` plan, which defined the tmux-based
  post-worktree hook this plan extends.
- `docs/plans/2026-04-14-001-feat-project-service-management-plan.md` —
  introduced the `run_command`/`service_env_var` pattern and the project
  card shape.

### External References

None gathered — local patterns are strong (System.cmd usage, setup_command
as a template, Mimic usage in existing worker tests), and the behavior
being added is a single shell invocation. External research would add
little practical value.

## Key Technical Decisions

- **Direct `System.cmd/3` instead of tmux.** The existing `setup_command`
  path routes through tmux's service window so the user can watch its
  output in the inline terminal. For `mise trust`, silent background
  execution is sufficient and preferable: it is a one-shot command, the
  output is not useful to the user in the common success case, and routing
  it through tmux would require either sharing window 9 with the
  user-owned `setup_command` (conflicts) or allocating another window
  (unjustified). Failures are logged server-side, which is consistent with
  the existing policy of not surfacing setup output to the web UI.
- **`try/rescue` around `System.cmd/3`.** A missing `mise` binary raises
  `ErlangError :enoent`, which is a normal condition on hosts without
  mise. Wrapping in `try/rescue` and logging lets the worker continue and
  preserves R7 (worktree readiness) without requiring the user to install
  mise.
- **No file-presence gating.** Per the user prompt, the flag alone drives
  the behavior. Checking for `.mise.toml`/`mise.toml`/`.tool-versions`
  would add complexity for no benefit — `mise trust -y` on a directory
  without mise configs exits non-zero, which we already log and ignore.
- **Run order is "mise before setup".** Guarantees that when a project has
  both the flag on and a `setup_command`, the setup command can use
  mise-managed tools. The mise step must execute even when `setup_command`
  is blank, so we cannot fold it into the existing `if blank?(setup_command)`
  branch — it lives above that check.
- **NOT NULL boolean column with `default: false`.** Matches the existing
  style of project boolean-ish columns, provides safe behavior for all
  existing rows without a backfill step, and removes the need for
  `nil`-handling in the worker or UI. The changeset's `cast/3` list
  handles validation; no custom validator is required because the DB
  default is safe and the form renders a checkbox (never `nil`).
- **Form checkbox placement.** The checkbox lives inside the existing
  "Service" grouping, immediately after the setup-command input, because
  it is most relevant to worktree setup. This keeps setup-related controls
  visually grouped without introducing a new section.

## Open Questions

### Resolved During Planning

- **Migration column type and nullability:** `add :mise_auto_trust,
  :boolean, null: false, default: false`. Resolved by matching the user
  prompt and Phoenix convention for boolean flags.
- **Should the checkbox be inside the existing "Service" fieldset
  grouping?** Yes, right under `setup_command`. Resolved by noting the
  feature's conceptual tie to setup-command behavior.
- **Should we use `Logger.warning/1` or `Logger.warn/1`?** `Logger.warning/1`,
  matching the existing `run_post_worktree_setup/3` `rescue` branch.
- **Should the card show the badge whether or not the project has a setup
  command?** Yes — the flag is independent of `setup_command` and users
  should be able to see at a glance that a project opts into auto-trust
  regardless of setup-command state.

### Deferred to Implementation

- **Exact DOM id for the checkbox.** Will follow the existing
  `"#{@id}-<field-kebab>"` convention; implementer will pick the final
  kebab form (e.g., `"#{@id}-mise-auto-trust"`).
- **Exact badge/icon used on the project card.** A single-line row using
  an existing hero icon (e.g., `hero-shield-check-micro`) is suggested;
  final icon choice deferred to implementation aesthetics.
- **Whether to coerce form checkbox params to booleans in the LiveView or
  rely on Ecto's boolean cast.** Either works; implementer will confirm
  once the checkbox renders and validates against the live form.

## Implementation Units

- [ ] **Unit 1: Schema and migration for `mise_auto_trust`**

**Goal:** Persist the new boolean flag on projects with a safe default and
expose it on the changeset.

**Requirements:** R1

**Dependencies:** None

**Files:**
- Create: `priv/repo/migrations/YYYYMMDDHHMMSS_add_mise_auto_trust_to_projects.exs`
- Modify: `lib/destila/projects/project.ex`

**Approach:**
- Add a new Ecto migration in the style of
  `priv/repo/migrations/20260416000000_add_setup_command_to_projects.exs`,
  adding `add :mise_auto_trust, :boolean, null: false, default: false` to
  `projects`. The `NOT NULL` + default ensures existing rows become
  `false` without an explicit backfill.
- Add `field(:mise_auto_trust, :boolean, default: false)` to the
  `Destila.Projects.Project` schema.
- Add `:mise_auto_trust` to the `cast/3` allow-list in
  `Project.changeset/2`. No custom validation needed.

**Patterns to follow:**
- Existing `setup_command` field definition and its migration.

**Test scenarios:**
- Happy path: creating a project without `mise_auto_trust` in attrs yields
  a persisted project whose `mise_auto_trust` is `false`.
- Happy path: creating a project with `mise_auto_trust: true` persists it
  as `true`.
- Happy path: updating a project flips the value and persists.

**Verification:**
- `mix ecto.migrate` applies cleanly; `mix ecto.rollback` reverses it.
- `Destila.Projects.create_project/1` and `update_project/2` accept and
  round-trip the new field through existing tests.

- [ ] **Unit 2: Add `Mimic.copy(System)` to test helper**

**Goal:** Enable Mimic stubbing of `System.cmd/3` in worker tests.

**Requirements:** R6, R7 (test infrastructure)

**Dependencies:** None (independent of Unit 1, but effectively required by
Unit 3's tests)

**Files:**
- Modify: `test/test_helper.exs`

**Approach:**
- Append `Mimic.copy(System)` to the list of `Mimic.copy/1` calls at the
  bottom of `test/test_helper.exs`.

**Patterns to follow:**
- Existing `Mimic.copy(Destila.Terminal.Tmux)`, `Mimic.copy(ExPTY)` etc.

**Test scenarios:**
- Test expectation: none -- this is pure test-infrastructure setup; Unit 3
  tests are what exercise the stubbing.

**Verification:**
- Unit 3 tests can successfully call `stub(System, :cmd, fn _, _, _ -> ... end)`
  without raising.

- [ ] **Unit 3: Wire `mise trust -y` into the worktree-preparation worker**

**Goal:** Run `mise trust -y` in the new worktree before the existing
`setup_command` branch when `project.mise_auto_trust == true`, tolerating
missing binary or non-zero exit.

**Requirements:** R2, R3, R4, R5, R6, R7

**Dependencies:** Unit 1 (field must exist), Unit 2 (test helper must copy
`System`)

**Files:**
- Modify: `lib/destila/workers/prepare_workflow_session.ex`
- Test: `test/destila/workers/prepare_workflow_session_test.exs`

**Approach:**
- In `run_post_worktree_setup/3`, add a new step ahead of the existing
  `if blank?(project.setup_command)` branch. The new step runs only when
  `project.mise_auto_trust == true` and uses
  `System.cmd("mise", ["trust", "-y"], cd: worktree_path, stderr_to_stdout: true)`
  wrapped in `try/rescue` to catch `ErlangError` (missing binary).
- On non-zero exit status, call `Logger.warning/1` with a message
  including the project id, workflow session id, and the combined output;
  do not raise.
- On rescued exception, call `Logger.warning/1` with the formatted
  exception; do not re-raise.
- Regardless of mise outcome, fall through to the existing `setup_command`
  logic so that a project with both `mise_auto_trust: true` and a
  `setup_command` runs both, and a project with only `mise_auto_trust: true`
  still completes setup cleanly.
- Keep the existing `nil`-project clause (`run_post_worktree_setup(nil, _, _)`)
  unchanged.

**Execution note:** Implement the new step test-first — the five new test
scenarios (flag on, flag off, blank setup, non-zero exit logged, raised
exception logged) describe externally observable behavior that is easier
to pin down before editing the worker.

**Patterns to follow:**
- The existing `try/rescue` + `Logger.warning/1` block in
  `run_post_worktree_setup/3`.
- `Destila.Git.pull/1` for `System.cmd/3` invocation shape.

**Test scenarios:**
- Happy path — flag on with setup command:
  `System.cmd/3` is called with `"mise"`, `["trust", "-y"]`, and
  `[cd: "/tmp/wt", stderr_to_stdout: true]`, stub returns `{"ok", 0}`;
  then tmux receives `send_keys` with the setup command. The mise call
  happens **before** the tmux send.
- Happy path — flag on without setup command: `System.cmd/3` is still
  called; no tmux `send_keys` is dispatched.
- Happy path — flag off: `System.cmd/3` is **not** called; if setup
  command is present it still runs.
- Error path — non-zero mise exit is logged, worker still returns `:ok`,
  and the subsequent setup command still runs (when present).
  Assert via `ExUnit.CaptureLog` that the log includes `warning` level and
  the combined stderr/stdout output.
- Error path — `System.cmd/3` stub raises `ErlangError` (simulating
  missing binary); worker returns `:ok`, the exception is logged at
  warning level, and the subsequent setup command still runs.
- Integration — when the project is `nil`, neither `System.cmd/3` nor
  tmux is invoked (existing behavior preserved).

**Verification:**
- `mix test test/destila/workers/prepare_workflow_session_test.exs` passes.
- `mix test --only feature:mise_auto_trust` runs the new scenarios.

- [ ] **Unit 4: Expose the flag in the project form**

**Goal:** Let users toggle `mise_auto_trust` at project-create and
project-edit time, defaulting to off.

**Requirements:** R1 (default off in UI), R8

**Dependencies:** Unit 1

**Files:**
- Modify: `lib/destila_web/live/project_form_live.ex`
- Test: `test/destila_web/live/projects_live_test.exs` (new assertions
  added near the existing setup_command tests)

**Approach:**
- Add `"mise_auto_trust" => project.mise_auto_trust || false` to the
  initial `to_form/1` map so edits hydrate the current value.
- Add a new `<fieldset class="fieldset">` inside the existing
  "Service" grouping, immediately after the setup-command field. Render a
  `<input type="checkbox" name="mise_auto_trust" value="true" />` with a
  label reading "Auto-trust mise" (or similar copy) and a short
  description clarifying that `mise trust -y` will run inside each new
  worktree.
- Add an unchecked hidden input (`<input type="hidden" name="mise_auto_trust" value="false" />`
  before the checkbox) so submits always include the field, matching the
  standard Phoenix checkbox pattern.
- In the `"save"` handler, coerce the submitted value to boolean and
  include `:mise_auto_trust` in the `attrs` map passed to
  `Projects.create_project/1` / `Projects.update_project/2`.
- Ensure validation-change (`"validate"` handler) continues to round-trip
  the checkbox state via the `to_form/1` re-assignment.

**Patterns to follow:**
- Existing inputs in the "Service" grouping; `setup_command` as the
  layout template; form `id` convention
  (`"#{@id}-<field-kebab>"`).

**Test scenarios:**
- Happy path — creating a project with the checkbox checked persists
  `mise_auto_trust: true`. Assert via `Destila.Projects.get_project/1`
  after `render_submit`.
- Happy path — creating a project without touching the checkbox yields
  `mise_auto_trust: false` (default-off behavior from the form).
- Happy path — editing an existing project flips the flag from `false` to
  `true` and persists. Re-rendering the form shows the checkbox in the
  new state.
- Edge case — editing a project with `mise_auto_trust: true` without
  changing the checkbox preserves `true` on save.
- Integration — form validation round-trip: `render_change` with the
  checkbox checked keeps it checked in the re-rendered form.

**Verification:**
- `mix test test/destila_web/live/projects_live_test.exs` passes.
- Manual smoke test: create a project with the flag on, confirm the DB
  row has `mise_auto_trust = true`.

- [ ] **Unit 5: Surface the enabled state on the project card**

**Goal:** Give users an at-a-glance signal that a project has
`mise_auto_trust` enabled.

**Requirements:** R8

**Dependencies:** Unit 1, Unit 4

**Files:**
- Modify: `lib/destila_web/live/projects_live.ex`
- Test: `test/destila_web/live/projects_live_test.exs`

**Approach:**
- In the display branch of each card
  (`:if={@editing_project_id != project.id}`), add a single conditional
  row inside the existing attribute column. The row renders only when
  `project.mise_auto_trust == true` and follows the same shape as the
  existing `setup_command` / `run_command` lines: an icon and a short
  label such as "auto-trust mise".
- Use `hero-shield-check-micro` (or another appropriate hero icon) per
  CLAUDE.md rules on icons.

**Patterns to follow:**
- The existing `<span :if={project.setup_command}>...</span>` rows.

**Test scenarios:**
- Happy path — rendering the projects list includes the auto-trust row
  for a project with `mise_auto_trust: true`.
- Happy path — the auto-trust row is absent for a project with
  `mise_auto_trust: false`.

**Verification:**
- `mix test test/destila_web/live/projects_live_test.exs` passes.

- [ ] **Unit 6: Gherkin — new `mise_auto_trust` feature file and link tags**

**Goal:** Add `features/mise_auto_trust.feature` containing the five
scenarios from the spec, and ensure new tests carry the correct
`@tag feature: "mise_auto_trust", scenario: "..."` annotations.

**Requirements:** R9

**Dependencies:** None (file can be added any time), but tests in Units 3
and 5 should reference it once it exists.

**Files:**
- Create: `features/mise_auto_trust.feature`
- Modify: `test/destila/workers/prepare_workflow_session_test.exs`
  (attach `@tag` annotations to the new tests added in Unit 3)
- Modify: `test/destila_web/live/projects_live_test.exs` (attach
  `@tag` annotations to the Unit 5 display-row tests — note: the
  card-display scenarios fit best as `feature: "project_management"` per
  Unit 7, but a targeted worker-oriented `@tag` for Unit 5 may use
  `feature: "mise_auto_trust"` if the scenario aligns; choose per-test)

**Approach:**
- Write `features/mise_auto_trust.feature` verbatim from the user prompt's
  scenarios section. Verify each scenario's title matches exactly what
  the tests tag.
- Add a module-level `@moduledoc` on the worker test module referencing
  the new feature file (mirroring the existing
  `Feature: features/service_setup_command.feature` annotation style).

**Patterns to follow:**
- Existing feature files under `features/` for voice, tense, and
  indentation.
- Existing `@moduledoc`/`@tag` linking in
  `test/destila/workers/prepare_workflow_session_test.exs`.

**Test scenarios:**
- Test expectation: none -- this unit is pure documentation + tag
  metadata. The runtime tests it references live in Units 3 and 5.

**Verification:**
- `mix test --only feature:mise_auto_trust` runs and matches the expected
  tests.
- Every scenario title in the feature file is referenced by at least one
  `@tag scenario: "..."` in the test suite.

- [ ] **Unit 7: Gherkin — extend `project_management.feature`**

**Goal:** Document the new form and card behavior in the project
management feature and link the form-level tests added in Unit 4.

**Requirements:** R9

**Dependencies:** Unit 4

**Files:**
- Modify: `features/project_management.feature`
- Modify: `test/destila_web/live/projects_live_test.exs`

**Approach:**
- Update the opening prose block in `features/project_management.feature`
  to mention the new optional `mise_auto_trust` boolean that defaults off.
- Append the three scenarios from the user prompt (create with
  auto-trust, default-off, edit toggling).
- Add `@tag feature: "project_management", scenario: "..."` to the Unit 4
  test cases so each scenario is linked.

**Patterns to follow:**
- Existing prose block at the top of `features/project_management.feature`
  and surrounding scenario indentation.
- Existing `@tag feature: @feature, scenario: "..."` usage in
  `test/destila_web/live/projects_live_test.exs`.

**Test scenarios:**
- Test expectation: none -- this unit is pure documentation + tag
  metadata.

**Verification:**
- `mix test --only feature:project_management` runs and includes the
  three new linked tests.

- [ ] **Unit 8: Precommit cleanup**

**Goal:** Ensure the branch passes the project's quality gate.

**Requirements:** All (final verification)

**Dependencies:** Units 1-7

**Files:**
- No source changes expected beyond fix-ups.

**Approach:**
- Run `mix precommit` and address any formatter, credo, compiler-warning,
  or unused-alias issues surfaced by the other units.

**Test scenarios:**
- Test expectation: none -- this unit is pure verification.

**Verification:**
- `mix precommit` exits 0.

## System-Wide Impact

- **Interaction graph:** The worker path `perform/1` ->
  `run_post_worktree_setup/3` ->
  `SessionProcess.worktree_ready/1` is extended by one new pre-setup
  step. No new callbacks, observers, or middleware.
- **Error propagation:** Mise failures are absorbed in a dedicated
  `try/rescue` and logged; they neither short-circuit `run_post_worktree_setup/3`
  nor prevent the existing tmux-based setup branch from running. The
  worker still returns `:ok` so `worktree_ready/1` is invoked.
- **State lifecycle risks:** None introduced. The mise step mutates host
  filesystem trust state under the user's home directory but performs no
  app-level persistence or cache writes.
- **API surface parity:** None — the flag is a read/write field on the
  `projects` table surfaced via the existing project form + card. No
  public API or webhook touches it.
- **Integration coverage:** The primary cross-layer interaction is
  worker -> external process (mise) -> logger. Covered by Unit 3's
  scenarios (flag on, flag off, blank setup, non-zero exit, raised
  exception). The form -> changeset -> persistence path is covered by
  Unit 4's LiveView tests.
- **Unchanged invariants:** `SessionProcess.worktree_ready/1` is still
  always called. `setup_command` delivery via tmux is unchanged. The
  `nil`-project short-circuit at the top of `run_post_worktree_setup/3`
  is preserved. Default behavior for all existing projects remains
  identical because the flag defaults to `false`.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `System.cmd("mise", ...)` raises on hosts without mise installed. | Wrap in `try/rescue`, log at warning level, continue. Covered by a dedicated test in Unit 3. |
| `mise trust -y` exits non-zero on worktrees without a mise config. | Per-spec: do not gate on file presence. Log the non-zero exit at warning level and continue. Covered by a test in Unit 3. |
| Checkbox submits default to absent when unchecked, leaving the attr missing from `params`. | Render a hidden `false` input immediately before the checkbox (standard Phoenix pattern) so `params["mise_auto_trust"]` is always present. |
| Test flakiness from calling real `System.cmd/3` when the stub isn't set. | `Mimic.copy(System)` in `test_helper.exs` plus per-test `stub(System, :cmd, ...)`. Any leakage raises a clear Mimic error rather than running the real binary. |
| Worktree readiness regressions if the new step is accidentally hoisted outside the `try/rescue`. | Code review + Unit 3's "raised exception" and "non-zero exit" scenarios both assert worktree readiness still happens. |

## Documentation / Operational Notes

- No new runtime dependencies or env vars.
- No migrations beyond the boolean column addition.
- No monitoring changes required. Warning logs from mise failures will
  appear in the standard worker log stream.
- Feature files under `features/` remain the BDD source of truth for the
  behavior; `mix test --only feature:mise_auto_trust` exercises it.

## Sources & References

- User prompt (this task): schema, worker integration, UI, test, and
  Gherkin guidance.
- Related code:
  - `lib/destila/projects/project.ex`
  - `lib/destila/workers/prepare_workflow_session.ex`
  - `lib/destila_web/live/project_form_live.ex`
  - `lib/destila_web/live/projects_live.ex`
  - `test/destila/workers/prepare_workflow_session_test.exs`
  - `test/destila_web/live/projects_live_test.exs`
  - `test/test_helper.exs`
- Related plans:
  - `docs/plans/2026-04-16-002-feat-project-setup-command-plan.md`
  - `docs/plans/2026-04-14-001-feat-project-service-management-plan.md`
- Related features:
  - `features/service_setup_command.feature`
  - `features/project_management.feature`
