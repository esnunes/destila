---
title: "feat: Project setup_command for pre-run installation/build"
type: feat
status: active
date: 2026-04-16
---

# feat: Project setup_command for pre-run installation/build

## Overview

Add an optional `setup_command` to projects that runs in the tmux service
window (index 9) in two situations:

1. Once, automatically, right after a session's worktree is created and its
   tmux session is ready — even if the service is never started.
2. Before every `run_command` on service start and restart.

`setup_command` and `run_command` are delivered in a single tmux `send_keys`
invocation chained with `;` (not `&&`), so a non-zero exit from setup still
lets `run_command` proceed. Setup output stays inside the tmux window and is
not streamed to the web UI. Existing projects without a setup command behave
exactly as they do today.

## Problem Frame

Projects in this app ship a `run_command` that is executed in a dedicated
tmux window to start a dev server (e.g., `mix phx.server`, `npm start`).
Real projects usually need dependency installation and/or asset building
before the server can run — `mix deps.get`, `npm install`, `mix assets.build`,
`bundle install`, etc. Today users have to either bake this into their
`run_command` (so it runs on every restart but not at worktree setup time)
or execute it manually in the tmux window.

A dedicated `setup_command` lets users express "prep work that should happen
automatically once the worktree is ready, and again before every run", while
keeping `run_command` focused on the long-running server process. Setup
running in the service window means any failure surfaces right where the user
would investigate run failures.

## Requirements Trace

- R1. A project may define an optional `setup_command` (string, nullable)
  alongside `run_command`.
- R2. When the worktree is created and the tmux session is ready, if the
  project has a `setup_command`, it runs in window 9 automatically —
  fire-and-forget, no completion tracking, even if the service is never
  started.
- R3. On every service `start` and `restart`, `setup_command` runs before
  `run_command` in the same tmux window, same `send_keys` call, chained with
  `;` so setup failure does not short-circuit run.
- R4. Port-definition env vars are exported before `setup_command`, so setup
  sees the same environment as `run_command`.
- R5. Setup output stays inside the tmux window; it is not streamed to the
  web UI.
- R6. Projects without `setup_command` keep their existing behavior exactly
  (no new shell chain, no new tmux work at worktree-ready time).
- R7. The project form supports editing `setup_command` next to
  `run_command`, and project cards display it when present.
- R8. Gherkin features are updated: `project_management.feature` scenarios
  cover the form/card surface; a new `service_setup_command.feature`
  covers the runtime behavior.

## Scope Boundaries

- The agent's bash PATH issue (bare `/bin/sh` not sourcing login profiles)
  is out of scope. Users can export needed paths inside their own
  `setup_command`.
- No completion tracking, exit-code surfacing, or UI progress indicators for
  setup. It is deliberately fire-and-forget beyond "we delivered the keys to
  tmux".
- No tmux integration tests. Tests assert on composed command strings and
  calls into the tmux helper layer only.
- No retries, no lock/debounce across concurrent starts. Callers already
  serialize start/stop/restart.
- No changes to the terminal streaming subsystem or `ServiceSidebar`.

## Context & Research

### Relevant Code and Patterns

- `lib/destila/projects/project.ex` — schema + changeset. `run_command` is
  declared here and cast; `setup_command` should mirror its declaration and
  position in `cast/3`. No validation needed beyond nullable string.
- `lib/destila/projects.ex` — CRUD + PubSub. Unchanged; `create_project/1`
  and `update_project/2` already pass attrs through the changeset.
- `lib/destila/services/service_manager.ex` — service lifecycle. Currently
  `build_service_command(run_command, ports)` produces:
    - `export PORT=x && export API_PORT=y && run_cmd` (ports present), or
    - `run_cmd` (no ports). `do_start/2` is the single caller.
    - `do_restart/2` delegates to `do_start/2`, so restart naturally
      re-runs setup — no restart-specific branching needed.
- `lib/destila/workers/prepare_workflow_session.ex` — creates the worktree
  and calls `SessionProcess.worktree_ready/1`. The setup-after-worktree hook
  goes between `create_worktree` and `worktree_ready`. The worker already
  calls `Destila.Projects.get_project/1`; we already have the project.
- `lib/destila/terminal/tmux.ex` — `ensure_session/2`, `new_window/2`,
  `send_keys/2`, `kill_window/1`, `window_exists?/1`. All already used by
  `ServiceManager.do_start/2`; reuse them in the worker hook.
- `lib/destila_web/live/project_form_live.ex` — form component. `run_command`
  lives in the "Service" fieldset; `setup_command` should sit next to it with
  the same pattern (label, `<input>`, value from `@form`, form-level
  validation/persistence).
- `lib/destila_web/live/projects_live.ex` — display template. The card shows
  `project.run_command` via a small icon/row; `setup_command` should get the
  same treatment when present (distinct icon, separate row).

### Institutional Learnings

- `docs/solutions/` is empty in this repo, so no prior learnings to carry
  forward.

### External References

None needed. The change is internal and follows existing patterns.

## Key Technical Decisions

- **Single tmux `send_keys`, chained with `;`**: Matches the stated
  behavior — setup failure does not short-circuit run. Implementing as
  `setup; run` preserves atomicity of the keystroke delivery (one
  keypress/Enter) and avoids race conditions between separate `send_keys`
  calls.
- **Shell-quote neither command**: Commands are already-user-supplied shell
  strings. Current `build_service_command` concatenates `run_command` raw,
  so `setup_command` is concatenated the same way. We preserve that existing
  trust model; no new escaping is introduced.
- **Post-worktree setup reuses `Tmux` helpers, not `ServiceManager`**:
  `ServiceManager.do_start/2` persists `service_state` and reserves ports.
  At worktree-ready time we intentionally do *not* want "running" state or
  a port reservation — we only want setup side-effects in the tmux window.
  Calling the tmux helpers directly from the worker keeps the separation
  clean and avoids a new `ServiceManager` entry-point just for this.
- **Port env exports also apply to post-worktree setup**: Ports are reserved
  using the same mechanism as `do_start`, so setup sees the same env in both
  contexts. This matches R4 and keeps setup behavior consistent whether it
  runs standalone or in front of `run_command`.
- **Window 9 is created (and potentially killed-and-recreated) by both
  paths**: The worker creates window 9 for setup; a later service start
  calls `kill_window` + `new_window` as it already does. Intentional and
  safe per constraints.
- **`build_service_command` arity changes**: from `(run_command, ports)` to
  `(setup_command, run_command, ports)`. Simpler than a keyword-option form,
  callers count is one (`do_start/2`).
- **Extract `build_service_command/3` as a public function** (or expose via
  `@doc false` + module attribute `@compile {:export_all, ...}` — no; just
  make it public): the testing requirement calls for a pure unit test on the
  composed shell string. Making it public with `@doc false` is the lightest
  change and follows the existing "small module, flat API" pattern in
  `ServiceManager`.

## Open Questions

### Resolved During Planning

- **Where does post-worktree setup run?** In `PrepareWorkflowSession`,
  between `create_worktree` and `SessionProcess.worktree_ready/1`, so tmux
  setup is in-flight by the time the UI considers the session "ready". The
  call is fire-and-forget and errors are ignored (worktree_ready does not
  depend on setup completing).
- **Does restart need a separate code path?** No. `do_restart/2` already
  calls `do_start/2`, which rebuilds the command string — so restart
  naturally re-runs setup.
- **Chain operator — `;` or `&&`?** `;`, per the prompt. Setup failing must
  not prevent `run_command` from executing.
- **Does post-worktree setup reserve ports?** Yes. Port env vars are
  exported so setup sees the same env. No persistence of ports happens —
  those sockets are closed immediately after getting the number, same as
  existing `reserve_ports/1`. A later `do_start/2` reserves its own fresh
  ports, which is fine.

### Deferred to Implementation

- **Exact column default/null behavior in migration**: `add :setup_command,
  :string` with no default; `NULL` is the absence signal. Confirm at write
  time.
- **Form field copy and placeholder**: Follow the existing "Run command"
  placeholder style — e.g., `mix deps.get && mix assets.build`. Final copy
  chosen during implementation.
- **Exact card icon for setup**: Pick a hero icon distinct from
  `hero-play-micro` (used for run_command) — likely `hero-wrench-micro` or
  `hero-cog-6-tooth-micro`. Final choice at implementation.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for
> review, not implementation specification. The implementing agent should
> treat it as context, not code to reproduce.*

Composed shell string produced by the service command builder, by inputs:

| setup_command | run_command  | ports         | Resulting shell string                                       |
|---------------|--------------|---------------|--------------------------------------------------------------|
| nil or ""     | `run_cmd`    | none          | `run_cmd`                                                    |
| nil or ""     | `run_cmd`    | `P=1, Q=2`    | `export P=1 && export Q=2 && run_cmd`                        |
| `setup_cmd`   | `run_cmd`    | none          | `setup_cmd; run_cmd`                                         |
| `setup_cmd`   | `run_cmd`    | `P=1, Q=2`    | `export P=1 && export Q=2 && setup_cmd; run_cmd`             |

Post-worktree setup (worker) sends only the setup part with exports prefixed:

| setup_command | ports         | Shell string sent to window 9                     |
|---------------|---------------|---------------------------------------------------|
| nil or ""     | any           | no setup invocation at all (skip the hook)        |
| `setup_cmd`   | none          | `setup_cmd`                                       |
| `setup_cmd`   | `P=1, Q=2`    | `export P=1 && export Q=2 && setup_cmd`           |

Sequence at worktree-ready time:

```mermaid
sequenceDiagram
    participant W as PrepareWorkflowSession
    participant T as Tmux
    participant S as SessionProcess
    W->>T: ensure_session(name, worktree_path)
    alt project has setup_command
        W->>T: kill_window(session:9)  (idempotent)
        W->>T: new_window(session:9, cwd: worktree_path)
        W->>T: send_keys(session:9, "export ... && setup_cmd")
    else no setup_command
        Note over W,T: skip; window 9 stays absent
    end
    W->>S: worktree_ready(workflow_session_id)
```

Sequence on service start:

```mermaid
sequenceDiagram
    participant SM as ServiceManager
    participant T as Tmux
    SM->>T: ensure_session(name, worktree_path)
    SM->>T: kill_window(session:9)
    SM->>T: new_window(session:9, cwd: worktree_path)
    SM->>T: send_keys(session:9, "export ... && setup_cmd; run_cmd")
    SM->>SM: persist service_state = running
```

## Implementation Units

- [ ] **Unit 1: Migration + schema field**

**Goal:** Persist `setup_command` on projects as a nullable string.

**Requirements:** R1

**Dependencies:** none

**Files:**
- Create: `priv/repo/migrations/20260416000000_add_setup_command_to_projects.exs`
- Modify: `lib/destila/projects/project.ex`
- Test: `test/destila/projects/project_test.exs`

**Approach:**
- Migration: `alter table(:projects) do add :setup_command, :string end`.
  No default; NULL means "absent". Mirror the form of
  `priv/repo/migrations/20260414000000_add_service_fields.exs`.
- Schema: add `field(:setup_command, :string)` directly under
  `:run_command`, and add `:setup_command` to the `cast/3` list in
  `changeset/2`. No new validations.

**Patterns to follow:**
- `priv/repo/migrations/20260414000000_add_service_fields.exs` for
  migration shape.
- `lib/destila/projects/project.ex` — mirror existing `run_command`
  declaration and cast positioning.

**Test scenarios:**
- Happy path: changeset with valid `setup_command` (e.g., `"mix deps.get"`)
  alongside existing valid attrs → `changeset.valid?` is true and
  `get_change(:setup_command)` returns the value.
- Happy path: changeset with `setup_command: nil` → valid (nullable).
- Edge case: changeset with `setup_command: ""` → valid (empty treated
  same as absent; no error added).
- Edge case: changeset without `setup_command` key in attrs → valid, no
  change to the field.
- Integration: `Destila.Projects.create_project/1` round-trips
  `setup_command` into the DB and `get_project/1` returns it on read.

**Verification:**
- `mix ecto.migrate` applies cleanly; `schema.ex` reflects the new field.
- Changeset tests pass; existing `project_test.exs` tests continue to pass.

- [ ] **Unit 2: Service command builder supports setup + refactor callers**

**Goal:** Produce the composed `export ... && setup_cmd; run_cmd` string
and pipe `setup_command` through from the project to `send_keys`.

**Requirements:** R3, R4, R6

**Dependencies:** Unit 1

**Files:**
- Modify: `lib/destila/services/service_manager.ex`
- Test: `test/destila/services/service_manager_test.exs` (new file)

**Approach:**
- Change `build_service_command/2` to `build_service_command/3` taking
  `(setup_command, run_command, ports)`. Make it public (with `@doc false`)
  so the test can call it directly.
- Treat `nil` and `""` setup_command as "no setup" and skip the `; setup`
  portion entirely — keeps R6 true.
- Update `do_start/2` to pass `project.setup_command` into the builder and
  to include `"setup_command"` in the persisted `service_state` map so the
  UI/debug views can see what ran.
- Do not alter `do_restart/2`; restart continues to delegate to
  `do_start/2`.

**Patterns to follow:**
- `build_service_command/2` in `lib/destila/services/service_manager.ex` —
  style and return contract.
- `service_state` map shape — keep keys as strings, mirror `"run_command"`.

**Test scenarios:**
- Happy path: builder with no setup, no ports → returns `run_cmd` exactly.
- Happy path: builder with no setup + ports → returns
  `"export P=1 && export Q=2 && run_cmd"` (order preserved).
- Happy path: builder with setup + ports → returns
  `"export P=1 && export Q=2 && setup_cmd; run_cmd"` (note the `;`, not
  `&&`, between setup and run).
- Happy path: builder with setup, no ports → returns
  `"setup_cmd; run_cmd"`.
- Edge case: builder with `setup_command: ""` behaves identically to
  `setup_command: nil`.
- Edge case: builder with empty ports map behaves like no ports.

**Verification:**
- New unit tests cover all six string-composition cases above.
- Manual read-through confirms `do_start/2` passes `project.setup_command`.

- [ ] **Unit 3: Post-worktree setup hook in PrepareWorkflowSession**

**Goal:** When a project has a `setup_command`, run it automatically in
tmux window 9 right after the worktree is created and before
`SessionProcess.worktree_ready/1` fires.

**Requirements:** R2, R4, R5

**Dependencies:** Unit 1

**Files:**
- Modify: `lib/destila/workers/prepare_workflow_session.ex`
- Test: `test/destila/workers/prepare_workflow_session_test.exs` (new file
  if not present)

**Approach:**
- After `create_worktree` succeeds and before the
  `SessionProcess.worktree_ready/1` call, branch on `project` and
  `project.setup_command`:
  - If `project` is nil, or `setup_command` is blank, do nothing.
  - Otherwise:
    - Compute a tmux session name via `Tmux.session_name/1`.
    - Call `Tmux.ensure_session/2` with `worktree_path`.
    - Reserve ports from `project.port_definitions` using the same
      mechanism `ServiceManager` already uses (extract a shared helper or
      duplicate the tiny function; preference: expose
      `ServiceManager.reserve_ports/1` as public `@doc false` and reuse,
      to keep parity).
    - Kill window 9 (idempotent) and create it with `cwd: worktree_path`.
    - `send_keys` with `"export P=1 && export Q=2 && setup_cmd"` (no
      `; run_cmd`, since there is no run at this point).
- Wrap the block in `try/rescue` so any tmux failure is logged but does
  not fail the worker — the worktree is still ready.
- Call `SessionProcess.worktree_ready/1` regardless of setup outcome.

**Patterns to follow:**
- `ServiceManager.do_start/2` for the `ensure_session → kill_window →
  new_window → send_keys` sequence.
- Existing worker style: thin `perform/1` with small private helpers.

**Test scenarios:**
- Happy path: project with `setup_command` and no ports → worker calls
  `Tmux.ensure_session`, `Tmux.new_window` for the service target, and
  `Tmux.send_keys` with `setup_cmd`; and `SessionProcess.worktree_ready/1`
  is called. Use `Mox` or a behavior-backed test double for `Tmux` (new
  testing seam).
- Happy path with ports: asserts `send_keys` receives
  `"export P=1 && ... && setup_cmd"` in order.
- Edge case: project with `setup_command: nil` → worker does NOT call
  `Tmux.new_window` or `Tmux.send_keys`; `worktree_ready/1` still fires.
- Edge case: project with `setup_command: ""` → treated the same as nil.
- Edge case: `project` is nil (no linked project) → no tmux calls;
  `worktree_ready/1` still fires.
- Error path: `Tmux.send_keys` raises → error is caught, logged, and
  `worktree_ready/1` still fires.
- Integration: given an Oban job with a valid workflow_session_id and a
  project with `setup_command`, the worker completes `{:ok, ...}` and the
  session process is notified.

**Verification:**
- Tests pass against a stubbed `Tmux` module (or extracted behavior).
- Manual exercise: create a project with `setup_command: "echo hi > /tmp/x"`,
  start a session, observe window 9 created and file written without ever
  starting the service.

- [ ] **Unit 4: Project form + card display**

**Goal:** Users can create/edit `setup_command` in the project form and
see it on the project card when present.

**Requirements:** R1, R7

**Dependencies:** Unit 1

**Files:**
- Modify: `lib/destila_web/live/project_form_live.ex`
- Modify: `lib/destila_web/live/projects_live.ex`
- Test: `test/destila_web/live/projects_live_test.exs`

**Approach:**
- Form component:
  - Add `"setup_command" => project.setup_command || ""` to the
    `to_form/1` map.
  - Add `setup_command: non_blank(params["setup_command"])` to the save
    `attrs` map.
  - Add a new `<fieldset>` and `<input>` for `setup_command` inside the
    existing "Service" rounded panel, placed above `run_command`. Use a
    sibling input id pattern: `#{@id}-setup-command`.
- Projects LiveView display:
  - In the card body, add a new `<span>` row for `project.setup_command`
    styled like the existing `project.run_command` row but with a distinct
    icon. Render with `:if={project.setup_command}` so absent/blank cases
    still look exactly as before (R6).

**Patterns to follow:**
- `run_command` form field in `project_form_live.ex` (lines around the
  "Service" panel) — mirror exactly.
- `run_command` display row in `projects_live.ex` (`hero-play-micro`) —
  mirror with a different icon.

**Test scenarios:**
- Happy path (create): user fills name, git URL, setup command, run
  command, clicks Create → project exists with the setup_command persisted;
  card shows both commands.
- Happy path (edit): project with existing `setup_command` → form input
  `#project-form-<id>-setup-command` is pre-filled; changing and saving
  updates the value and the card reflects the new value.
- Edge case: creating without setup_command still works and card shows no
  setup row (R6 parity).
- Edge case: edit clears setup_command to empty string → stored as `nil`
  by `non_blank/1`, card hides the row.
- Happy path (linked Gherkin): scenarios from
  `project_management.feature` — "Create a project with a setup command"
  and "Edit a project's setup command".

**Verification:**
- All new tests in `projects_live_test.exs` pass.
- Visual check: the form layout is balanced (two inputs in the Service
  panel), the card shows the new row only when populated.

- [ ] **Unit 5: Gherkin features**

**Goal:** Update/append Gherkin so the feature files match implemented
behavior.

**Requirements:** R8

**Dependencies:** Units 3 and 4 must reflect the behavior the scenarios
describe. File edits can happen in parallel with implementation as long
as tests link back.

**Files:**
- Modify: `features/project_management.feature`
- Create: `features/service_setup_command.feature`

**Approach:**
- Update the `project_management.feature` header's field list to include
  `setup_command`. Add the two scenarios from the prompt verbatim.
- Create `features/service_setup_command.feature` with the feature
  description and six scenarios from the prompt verbatim.
- Add `@tag feature: "...", scenario: "..."` to each new LiveView test
  linked to the corresponding scenario; for runtime scenarios in
  `service_setup_command.feature`, tag the worker/service tests
  introduced in Units 2 and 3.

**Patterns to follow:**
- `features/project_management.feature` — feature header format, indent.
- Tag-linking style used in `test/destila_web/live/projects_live_test.exs`
  (`@feature` module attribute, per-test `@tag feature:, scenario:`).

**Test scenarios:**
- Test expectation: none — this unit adds documentation artifacts, not
  behavior. Verification is that `mix test --only feature:project_management`
  and `mix test --only feature:service_setup_command` both run and every
  scenario has at least one linked test (spot-check).

**Verification:**
- `grep -c "Scenario:" features/project_management.feature` increases by 2.
- `features/service_setup_command.feature` exists with 6 scenarios.
- Running `mix test --only feature:service_setup_command` selects the
  tests added in Units 2 and 3.

## System-Wide Impact

- **Interaction graph:**
  - `PrepareWorkflowSession` now makes outbound `Tmux` calls — previously
    it only touched Git, the DB, and `SessionProcess`. This introduces a
    new side-effect at worktree-ready time.
  - `ServiceManager.build_service_command` signature changes; the only
    internal caller is `ServiceManager.do_start/2`. If other call sites
    exist (search confirmed none), they must be updated in lockstep.
  - `service_state` map gains a `"setup_command"` key; the debug sidebar
    and any consumer of that blob should tolerate the new key. Spot-check
    `lib/destila_web/live/service_status_sidebar_live.ex` if it renders
    the map.
- **Error propagation:** Setup failures do not propagate to the user —
  they land in tmux only. Worker-level tmux invocation errors are caught
  and logged so `worktree_ready/1` always fires.
- **State lifecycle risks:**
  - Window 9 may exist from the worker hook before any `do_start` runs; a
    later `do_start` `kill_window`s and recreates it — safe and intentional.
  - Port reservation at worktree-ready time closes the listening sockets
    immediately; a later `do_start` reserves its own fresh ports. There is
    a small window where the reserved port could be taken by another
    process before `do_start` runs, but port reservations are already
    best-effort — no regression.
  - `Tmux.kill_window/1` is called idempotently; absent window returns
    non-zero but we discard the return tuple.
- **API surface parity:** No external API changes. Internal function
  signature of `ServiceManager.build_service_command` changes; making it
  public with `@doc false` documents the testing seam.
- **Integration coverage:** LiveView tests cover the form/card surface.
  Unit tests cover the string builder. Worker test covers the branch
  logic and tmux call sequence via a stubbed tmux module. No tmux
  integration test per explicit scope.
- **Unchanged invariants:**
  - Projects without `setup_command` produce identical shell strings and
    identical tmux call sequences as today (R6).
  - `do_restart/2` continues to delegate to `do_start/2` — no new code
    path.
  - `SessionProcess.worktree_ready/1` is always called, exactly once, per
    worker run.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `build_service_command` has a hidden caller we missed, breaking compile on arity change. | Before editing, `grep -r "build_service_command"` across `lib/` and `test/`. Only call site found is `do_start/2`. |
| Worker hook racing with a service start kicked off immediately after worktree-ready (setup window gets killed mid-setup). | Acceptable: explicit per constraints. `do_start/2` `kill_window`s window 9 and re-runs setup via the builder, so the user still gets setup. |
| `Tmux.ensure_session/2` called from the worker duplicates work that `ServiceManager` will redo on start. | Acceptable — `ensure_session/2` is idempotent (no-ops when session exists). |
| Users misuse `;` semantics and expect setup failure to block run. | Documented explicitly in the feature file description. No behavioral change to accommodate. |
| Port reservation from the worker transiently holds ports that something else could grab before `do_start`. | Low — existing `reserve_ports/1` already closes the socket immediately; no regression vs. today's behavior. |

## Documentation / Operational Notes

- `CLAUDE.md` does not need updates; the `setup_command` is a runtime
  project attribute, not an authoring convention.
- No rollout flag; schema migration is additive and nullable. Existing
  projects behave as before.
- No monitoring changes. Worker logs are the only new diagnostic surface
  for setup invocation failures.

## Sources & References

- Origin document: none (planning direct from prompt).
- Related code:
  - `lib/destila/projects/project.ex`
  - `lib/destila/projects.ex`
  - `lib/destila/services/service_manager.ex`
  - `lib/destila/workers/prepare_workflow_session.ex`
  - `lib/destila/terminal/tmux.ex`
  - `lib/destila_web/live/project_form_live.ex`
  - `lib/destila_web/live/projects_live.ex`
- Related migration: `priv/repo/migrations/20260414000000_add_service_fields.exs`
- Related feature files: `features/project_management.feature`
