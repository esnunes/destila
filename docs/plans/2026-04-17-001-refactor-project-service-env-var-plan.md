---
title: Refactor project service configuration to a single service env var
type: refactor
status: active
date: 2026-04-17
---

# Refactor project service configuration to a single service env var

## Overview

Replace the multi-port `port_definitions` array on `Destila.Projects.Project` with a single optional `service_env_var` string. Presence of this value marks the project as a webservice — no separate boolean flag. Ports are allocated only when the service starts or restarts for a webservice project, and the service AI tool returns a single `url` string instead of a `ports` map.

## Problem Frame

The current design treats "ports" as a first-class, multi-valued configuration on projects: `port_definitions` is an array of env var names (`["PORT", "API_PORT"]`), and the service lifecycle reserves one ephemeral port per name and exports each as an env var. Downstream (service sidebar link, MCP AI tool, AI conversation context) only ever surfaces the *first* port, which leaks multi-port complexity into a UI that can only present a single URL. Additionally, `PrepareWorkflowSession` currently reserves ports for the post-worktree setup run, even though nothing consumes that allocation — the setup command just happens to see the env vars.

The refactor collapses the model to its actual usage: a project is a webservice when it has a single env var name declared. A single port is allocated on start/restart, exported as that env var, and the service URL is `http://localhost:<port>`. Post-worktree setup runs without any port allocation.

## Requirements Trace

- **R1.** Replace `port_definitions` array with a single optional `service_env_var` string on `Destila.Projects.Project`, validated by the existing `^[A-Z][A-Z0-9_]*$` regex and the reserved-name denylist (`PATH`, `HOME`, `SHELL`, `USER`, `TERM`, `LANG`, `LD_PRELOAD`, `LD_LIBRARY_PATH`).
- **R2.** A project is a webservice iff it has both `run_command` and a non-empty `service_env_var`. Empty string is equivalent to nil.
- **R3.** `ServiceManager.start`/`restart` reserve exactly one ephemeral port, export it as the configured env var, and send `setup_command; run_command` (or just run command) to the tmux service window. Both actions require the webservice preconditions; otherwise they return a clear error.
- **R4.** `PrepareWorkflowSession` always runs the setup command after worktree creation when a setup command is configured, with no port allocated and no env var exported. Failures remain logged and non-blocking.
- **R5.** `service_state` persists a scalar `port` integer (not a `ports` map), plus `status`, `run_command`, `setup_command`. Stop/status/cleanup paths update accordingly.
- **R6.** The `mcp__destila__service` tool returns a JSON object with `status`, `run_command`, `setup_command`, and a single `url` of the form `http://localhost:<port>`. `url` is omitted when no port is allocated. The tool's description states the project-must-be-a-webservice precondition.
- **R7.** The service sidebar item renders only when the project has both `run_command` and `service_env_var`. When the service is running it links to `http://localhost:<port>` opening in a new tab. Otherwise it is hidden. Running vs. stopped/nil continues to drive icon color.
- **R8.** The project form replaces the multi-port input with a single optional text input for `service_env_var` and surfaces validation errors on that field.
- **R9.** Legacy `service_state` values still shaped like `%{"ports" => %{...}}` after deploy are tolerated: treated as stopped-with-no-url for reads; the next start/restart refreshes them to the new shape.
- **R10.** Gherkin scenarios in `features/project_management.feature`, `features/service_status_sidebar.feature`, and `features/service_setup_command.feature` are updated per the user's prompt. Tests referencing `port_definitions` or the `ports` map are updated to match the new contract. `mix precommit` passes.

## Scope Boundaries

- Existing `port_definitions` data is **discarded**: one migration drops the column and adds `service_env_var`. No data-preserving backfill.
- Multi-port support is fully removed — no adapter layer, no "ports list with a primary" intermediate shape.
- No changes to tmux window index (stays at 9), port probe timing, or `@startup_timeout_ms`.
- No new UI affordances beyond replacing the existing port definitions input.
- No change to the AI session/worktree lifecycle beyond dropping the port reservation inside `run_post_worktree_setup/3`.
- AI conversation context (`build_service_section/1` in `lib/destila/ai/conversation.ex`) is updated mechanically to use the new shape; no prompt-engineering changes beyond that.

## Context & Research

### Relevant Code and Patterns

- **Schema + validator:** `lib/destila/projects/project.ex` — `port_definitions` array, `@port_definition_pattern`, `@denied_env_vars`, `validate_port_definitions/1`. Existing regex/denylist and `Ecto.Changeset.validate_format/3` + `validate_change/3` patterns are reused for the scalar field.
- **ServiceManager:** `lib/destila/services/service_manager.ex` — `do_start/2`, `do_stop/2`, `do_restart/2`, `do_status/2`, `reserve_ports/1`, `build_service_command/3`, `cleanup/1`. The existing `cond`-based precondition pattern at the top of `do_start/2` is the template for adding the new `service_env_var` precondition.
- **Worktree setup:** `lib/destila/workers/prepare_workflow_session.ex` — `run_post_worktree_setup/3`, `build_setup_command/2`. Keep the rescue-and-log pattern that makes setup failures non-blocking.
- **MCP tool:** `lib/destila/ai/tools.ex` — `tool :service` block and its `execute/2`. JSON response is produced by `Jason.encode!(state)`; switching the returned map is sufficient.
- **AI conversation context:** `lib/destila/ai/conversation.ex:254-268` — `build_service_section/1` currently iterates the `ports` map; update to read scalar `port` and the project's `service_env_var`.
- **Sidebar:** `lib/destila_web/live/workflow_runner_live.ex:827-935` for rendering; `service_url/2` at lines 1288-1299 for URL derivation. The existing `cond`/pattern-match approach on `service_state` is preserved.
- **Form:** `lib/destila_web/live/project_form_live.ex` — replace array add/remove/update handlers with a single `<.input>` bound to the form, following the Phoenix v1.8 form conventions already used for `name`, `run_command`, and `setup_command`.
- **Feature/test pairing:** `@tag feature: "...", scenario: "..."` annotations are already the project's convention (see `test/destila_web/live/service_status_sidebar_live_test.exs`, `test/destila_web/live/projects_live_test.exs`).

### Institutional Learnings

- No direct `docs/solutions/` hit for this refactor. Adjacent prior work lives at `docs/plans/2026-04-14-001-feat-project-service-management-plan.md` (introduced the current port_definitions model) and `docs/plans/2026-04-16-002-feat-project-setup-command-plan.md` (introduced the `setup_command; run_command` chaining). Both are the conventions to continue matching.

### External References

- None required: this is a bounded refactor of in-repo primitives with no new framework surface. Phoenix LiveView form conventions, Ecto changeset validators, and Oban worker patterns already in-repo are sufficient.

## Key Technical Decisions

- **Single migration, no backfill.** Per the prompt, drop `port_definitions` and add `service_env_var` in one migration; existing values are discarded. Rationale: product is pre-production; multi-port data is not worth migrating to a single value.
- **Empty string ≡ nil.** The form may submit `""`. Normalize blank strings to `nil` at the changeset boundary (same pattern already used for `run_command`, `setup_command` in `project_form_live.ex`'s `non_blank/1`). Rationale: keeps the "is a webservice?" predicate a simple `present?` check across readers.
- **Preconditions computed in one place.** A private `Project.webservice?/1` predicate (non-exhaustive public API — just a private helper on the struct or a `Projects` context helper) is defined once and reused by `ServiceManager`, the sidebar, the MCP tool, and `build_service_section/1`. Rationale: one source of truth for "both `run_command` and `service_env_var` are present and non-blank".
- **`service_state["port"]` is scalar int or absent.** Not `nil` in the map — absent. Rationale: the MCP tool's JSON must omit `url` when there is no port; the cleanest way is to never put `port` in the state map when there isn't one (e.g., after a `do_stop/2` that never ran before, or a legacy `ports`-shaped record on read).
- **Tolerate legacy `%{"ports" => _}` service_state on read.** Every reader (sidebar URL, status checks, MCP tool, AI conversation context) matches on `state["port"]`/missing and ignores an unknown `state["ports"]` key. The next start/restart rewrites it. Rationale: avoids a separate data migration without keeping a compat branch forever.
- **Error message copy on precondition failure.** `do_start`/`do_restart` return `{:error, "Project is not configured as a webservice (requires run_command and service_env_var)"}` when either is missing. The MCP tool propagates this through its existing `"Service error: #{reason}"` path. Rationale: one message covers both missing-command and missing-env-var cases, matching how the current "no run command" error is surfaced.
- **Post-worktree setup uses a plain command.** `PrepareWorkflowSession.run_post_worktree_setup/3` drops the `ServiceManager.reserve_ports/1` call and sends `setup_command` verbatim to tmux (no env exports). Rationale: per the prompt, this path is not a service start and should not touch ports.
- **Form field type is plain text input.** Reuse `<.input type="text">` with the existing form; do not invent a new component. Rationale: matches the other project fields and avoids bespoke UI for a one-line string.

## Open Questions

### Resolved During Planning

- **Should the DB column be dropped in the same migration that adds `service_env_var`?** Yes — per the prompt, one migration, no data preservation.
- **How do we express the `url` absence in JSON?** Omit the key from the map before `Jason.encode!/1`. `Jason` does not emit missing keys; this yields `{"status":"stopped", ...}` without a `url` field.
- **Does post-worktree setup need any env var exported?** No — the prompt is explicit. Plain command only.
- **Where does the `webservice?` check live?** As a private helper. It is *not* exposed on the schema struct as a virtual field; it is a derived predicate used by a handful of callers. Adding a `Projects.webservice?/1` helper in the `Destila.Projects` context and importing at call sites is acceptable; keeping it inline as a local `if` is also acceptable. Implementation unit allows either — see Unit 2 Approach.
- **What happens to `service_state` on a project that loses webservice configuration later (env var cleared on an existing project)?** Next `do_start` returns the precondition error and the session's existing `service_state` is unchanged (possibly "running" for a stale process). The sidebar will hide the item entirely once the project no longer qualifies, so the stale state is not user-visible. Acceptable.

### Deferred to Implementation

- Final method/helper names (e.g., `Projects.webservice?/1` vs. a private `service_env_var_present?/1` helper in each module).
- Exact tmux `send_keys` string after the `build_service_command/3` refactor — prose shows the shape, but the final concatenation is decided when writing the code.
- Whether the `:service_env_var` cast uses `validate_format` + `validate_change` (matching the current two-step pattern) or a single `validate_change` that runs both checks. Either is fine.
- Exact wording of the MCP tool description update beyond "requires the project to be configured as a webservice (run command + service env var)".

## High-Level Technical Design

> *This illustrates the intended shape and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

**Service lifecycle state transitions (new shape):**

```
┌──────────────┐   start/restart   ┌───────────┐   ports respond   ┌─────────┐
│  stopped /   │ ────────────────▶ │  starting │ ────────────────▶ │ running │
│     nil      │   (reserve 1      │           │                   │         │
│              │    port, export   └───────────┘                   └─────────┘
│              │    ENV=port)           │                                │
│              │                        │ timeout / stop                 │ stop
│              │◀───────────────────────┴────────────────────────────────┘
└──────────────┘

service_state (after refactor):
  %{
    "status"          => "starting" | "running" | "stopped",
    "port"            => 4712,                     # omitted when no port reserved
    "run_command"     => "mix phx.server",
    "setup_command"   => "mix deps.get"            # may be nil
  }
```

**MCP tool JSON contract:**

```
  running   →  {"status":"running","url":"http://localhost:4712","run_command":"...","setup_command":"..."}
  stopped   →  {"status":"stopped","run_command":"...","setup_command":"..."}              # no url key
  starting  →  {"status":"starting","url":"http://localhost:4712","run_command":"...","setup_command":"..."}
  precond   →  "Service error: Project is not configured as a webservice (requires run_command and service_env_var)"
```

**Webservice predicate (one source of truth):**

```
  webservice?(project) :=
      present?(project.run_command) AND present?(project.service_env_var)
```

**Post-worktree setup path (setup only, no port):**

```
  PrepareWorkflowSession.perform
    └─ run_post_worktree_setup(project, worktree, ws)
         └─ if project.setup_command present:
              send_keys(service_window, project.setup_command)       # no exports
              # failures rescued + logged; worktree still marked ready
```

## Implementation Units

- [ ] **Unit 1: Schema + migration for `service_env_var`**

**Goal:** Replace `port_definitions` with `service_env_var` on the Project schema and database.

**Requirements:** R1, R2, R10

**Dependencies:** None.

**Files:**
- Create: `priv/repo/migrations/YYYYMMDDHHMMSS_replace_port_definitions_with_service_env_var.exs`
- Modify: `lib/destila/projects/project.ex`
- Test: `test/destila/projects/project_test.exs`

**Approach:**
- Single migration: `alter table(:projects) do remove :port_definitions; add :service_env_var, :string end`. No backfill, no default.
- Schema: drop `field(:port_definitions, {:array, :string}, default: [])`; add `field(:service_env_var, :string)`.
- Changeset: cast `:service_env_var`; replace `validate_port_definitions/1` with a `validate_service_env_var/1` that:
  - Short-circuits when the value is `nil` or blank (project is simply not a webservice).
  - Otherwise applies the existing `@port_definition_pattern` and `@denied_env_vars` checks.
  - Keep the `@port_definition_pattern` and `@denied_env_vars` module attributes; rename if it reads more clearly (e.g., `@env_var_pattern`), but mechanical rename only.
- Normalize blank strings to `nil` in the form handler (Unit 5) so the changeset predicate stays simple.

**Patterns to follow:**
- The existing `validate_required`, `validate_change` pipeline in `lib/destila/projects/project.ex`.
- Migration style used in `priv/repo/migrations/20260414000000_add_service_fields.exs` and `20260416000000_add_setup_command_to_projects.exs` (plain `alter table`).

**Test scenarios:**
- Happy path: changeset accepts a valid uppercase identifier (`"PORT"`, `"API_PORT"`, `"MY_SERVICE_PORT"`) → `changeset.valid?` is true and `get_change(changeset, :service_env_var)` returns the value.
- Happy path: changeset accepts `nil` / omitted `service_env_var` → valid.
- Edge case: changeset normalizes empty string to nil (or accepts it as valid non-webservice state — specific behavior depends on Unit 5 normalization, but the changeset itself must not emit a format error on `""`).
- Error path: lowercase value (`"port"`) → error message matches the existing `validate_port_definitions` wording adapted to the scalar field.
- Error path: starts with digit (`"1PORT"`) → format error on `:service_env_var`.
- Error path: contains special char (`"PORT-1"`, `"PORT.1"`) → format error.
- Error path: each reserved name in `@denied_env_vars` → reserved-name error (parameterize or enumerate at minimum `PATH`, `HOME`, `LD_PRELOAD`).
- Edge case: underscores in the middle and multi-digit suffixes allowed (`"SERVICE_PORT_2"`).
- Delete: existing tests referencing `port_definitions` in this file are removed or rewritten to point at `service_env_var`.

**Verification:**
- `mix ecto.migrate` applies cleanly on a dev DB; `mix ecto.rollback` is not a requirement (fresh-data refactor).
- `mix test test/destila/projects/project_test.exs` passes.

---

- [ ] **Unit 2: `ServiceManager` lifecycle — scalar port and webservice precondition**

**Goal:** Make `start`/`restart` require both `run_command` and `service_env_var`, reserve a single ephemeral port, export it under the configured env var, and persist scalar `port` in `service_state`.

**Requirements:** R3, R5, R9

**Dependencies:** Unit 1.

**Files:**
- Modify: `lib/destila/services/service_manager.ex`
- Test: `test/destila/services/service_manager_test.exs`

**Approach:**
- Update `do_start/2`'s `cond` to additionally check `blank?(project.service_env_var)` and return `{:error, "Project is not configured as a webservice (requires run_command and service_env_var)"}` when either precondition fails. Fold the existing "Project has no run command configured" branch into the single webservice precondition message (simpler UX; matches the prompt's "not configured as a webservice" wording).
- Replace `reserve_ports/1`'s map-building with a scalar helper `reserve_port/0` returning `integer` (or inline the 4-line `gen_tcp.listen → :inet.port → close` block in `do_start`). Keep it as a `@doc false` testable function for the new unit tests.
- Rework `build_service_command/3` into `build_service_command(setup_command, run_command, env_var, port)`:
  - `env_export = "export #{env_var}=#{port}"`
  - `body = if blank?(setup_command), do: run_command, else: "#{setup_command}; #{run_command}"`
  - Returns `"#{env_export} && #{body}"`.
- `starting_state` becomes `%{"status" => "starting", "port" => port, "run_command" => ..., "setup_command" => ...}`.
- `wait_for_ports/2` loses its list — replace with `wait_for_port(port, @startup_timeout_ms)`.
- `do_stop/2`'s preserved state becomes `%{"status" => "stopped", "port" => (ws.service_state || %{})["port"]}`. If no prior port, omit `"port"` entirely (use `Map.put_new_lazy` or conditional `Map.put`). This ensures cleanliness for fresh stops and graceful tolerance of legacy `%{"ports" => _}` state (the `"port"` key is absent and so is omitted, matching R9).
- `do_status/2` logic is unchanged structurally; it still flips `"running"` → `"stopped"` when the tmux window is gone.
- `cleanup/1` unchanged (still writes `service_state: nil`).

**Patterns to follow:**
- Existing `cond` precondition block at the top of `do_start/2`.
- Existing log-and-return pattern on startup timeout.
- `Workflows.update_workflow_session/2` shape already used for state persistence.

**Test scenarios:**
- Happy path: `build_service_command/4` with `setup_command = nil`, `run_command = "run"`, env var `"PORT"`, port `4712` → `"export PORT=4712 && run"`.
- Happy path: with `setup_command = "setup"` → `"export PORT=4712 && setup; run"`.
- Edge case: `setup_command = ""` treated as blank → `"export PORT=4712 && run"` (no `;`).
- Error path (integration): `do_start` on a session whose project has `run_command` but `service_env_var = nil` → returns `{:error, "Project is not configured as a webservice" <> _}`; service_state is unchanged.
- Error path: same, with `service_env_var` set but `run_command = nil` → same error.
- Error path: no project linked → existing "No project linked to this session" error preserved.
- Integration: `do_start` success path writes `service_state` with scalar `"port"` integer, `"status" => "running"`, and includes `run_command`/`setup_command` fields.
- Edge case: `do_stop` on a session whose prior `service_state` was the legacy `%{"ports" => %{...}}` shape → returns `{:ok, state}` with `status: "stopped"` and **no** `"port"` key in the map; does not raise.
- Edge case: `do_stop` on nil `service_state` → `{:ok, %{"status" => "stopped"}}` (no `"port"` key).

**Verification:**
- `mix test test/destila/services/service_manager_test.exs` passes.
- No references to `port_definitions` or a `ports` map remain in `lib/destila/services/service_manager.ex`.

---

- [ ] **Unit 3: `PrepareWorkflowSession` — setup without port allocation**

**Goal:** Always run `setup_command` (when present) after worktree creation as a plain command. Do not reserve ports or export env vars in this path.

**Requirements:** R4

**Dependencies:** Unit 2 (so the removed `reserve_ports/1` call is not a dangling reference).

**Files:**
- Modify: `lib/destila/workers/prepare_workflow_session.ex`
- Test: `test/destila/workers/prepare_workflow_session_test.exs`

**Approach:**
- Remove the `ServiceManager.reserve_ports(project.port_definitions)` call.
- Remove `build_setup_command/2` entirely (or reduce it to a no-op passthrough; prefer removal).
- `send_keys(target, project.setup_command)` directly.
- Keep the surrounding `try/rescue` with `Logger.warning` and the `:ok` return so worktree readiness is not blocked on failure.
- Behavior still gated on `if blank?(project.setup_command), do: :ok, else: ...`.
- `run_post_worktree_setup(nil, _, _)` guard clause unchanged.

**Patterns to follow:**
- Existing guard-clause + try/rescue shape in the same module.

**Test scenarios:**
- Happy path: project with a setup command and no env var set → `send_keys` is called with exactly the `setup_command` string (no `export FOO=...` prefix).
- Happy path: project with a setup command and a `service_env_var` set → `send_keys` is still called with exactly `setup_command` (the prompt is explicit: no env var exported in the post-worktree path).
- Edge case: project with `setup_command = nil` or `""` → `send_keys` is not called.
- Edge case: project with no setup command but with `run_command` + `service_env_var` → `send_keys` is not called (no service started here; setup is the only trigger).
- Error path: tmux raises — worker logs and returns `:ok`; the workflow session is still marked worktree-ready (reassert the existing behavior).
- Edge case: `project == nil` → guard clause returns `:ok` without tmux interaction.

**Verification:**
- `mix test test/destila/workers/prepare_workflow_session_test.exs` passes.

---

- [ ] **Unit 4: MCP `service` tool — scalar `url` in JSON output**

**Goal:** Update the MCP tool's JSON response shape to use a single `url` and update the tool description.

**Requirements:** R6, R9

**Dependencies:** Unit 2.

**Files:**
- Modify: `lib/destila/ai/tools.ex`
- Modify: `lib/destila/ai/conversation.ex` (`build_service_section/1`)
- Test: any tests exercising the MCP service tool output (search under `test/destila/ai/` and update or add as needed).

**Approach:**
- In `tool :service`:
  - Update the tool `description/1` to include the webservice precondition: e.g., *"Manage the project's development service lifecycle (start/stop/restart/status). Requires the project to be configured as a webservice (a run command and a service env var name)."*
  - In `execute/2`, after `ServiceManager.execute/3` returns `{:ok, state}`, transform the map before encoding:
    - Base: `%{"status" => state["status"], "run_command" => state["run_command"], "setup_command" => state["setup_command"]}`.
    - If `state["port"]` is an integer, add `"url" => "http://localhost:#{port}"`.
    - Never emit `"http://localhost:"` with no port — controlled by the conditional `Map.put`.
    - Do not leak internal keys like `"port"` into the JSON output; `url` is the external contract.
- Update `lib/destila/ai/conversation.ex:254-268` (`build_service_section/1`) to read scalar `state["port"]` instead of iterating `state["ports"]`. When no port is present and status is not `nil`, render `"# Service Status\n\nThe project service is currently #{status}."` with no URL line. When a port is present, render `"\nURL: http://localhost:<port>"` (consistent with the external contract). Tolerate unknown legacy shapes by treating missing `"port"` as "no URL".
- Also update the top-of-file prompt/documentation block (the block under `# Tools\n\n## Service Management`) if it references "port mappings" — swap to "and service URL when running".

**Patterns to follow:**
- Existing `try/rescue` in `execute/2` that wraps errors as `"Service error: ..."`.
- Existing `Jason.encode!/1` pattern — no change to encoding strategy, only to the map.

**Test scenarios:**
- Happy path (unit-level): given a state map with `"status" => "running", "port" => 4712, "run_command" => "...", "setup_command" => "..."`, the encoded JSON contains `"url":"http://localhost:4712"` and `"status":"running"`.
- Happy path (stopped): state map with `"status" => "stopped"` and no `"port"` key → encoded JSON has `"status":"stopped"` and does **not** contain `"url"`.
- Happy path (starting): state map with `"status" => "starting", "port" => 4712` → `"url":"http://localhost:4712"`.
- Error path: when `ServiceManager.execute/3` returns `{:error, "Project is not configured as a webservice ..."}`, the tool returns `"Service error: Project is not configured as a webservice ..."`.
- Edge case (legacy state): a legacy state shape like `%{"status" => "running", "ports" => %{"PORT" => 4712}}` fed to the JSON transform is treated as no-port → JSON contains no `"url"`. (This is a unit-level transform test; realistically the next start rewrites the state.)
- Conversation context: `build_service_section/1` with new shape renders the `URL:` line with scalar port; with missing `"port"` renders no URL line; nil state returns nil.

**Verification:**
- `mix test` for tool and conversation modules passes.
- Grep: no remaining `state["ports"]` reads under `lib/destila/ai/`.

---

- [ ] **Unit 5: Project form UI — single `service_env_var` input**

**Goal:** Replace the port-definitions list UI with a single optional text input bound to `service_env_var`, surfacing validation errors on that field.

**Requirements:** R8, R10

**Dependencies:** Unit 1.

**Files:**
- Modify: `lib/destila_web/live/project_form_live.ex`
- Test: `test/destila_web/live/projects_live_test.exs`

**Approach:**
- Remove the `port_definitions` assign, `add_port` / `remove_port` / `update_port` handlers, and the `params |> filter("port_def_")` logic in `handle_event("validate", ...)`.
- Use a single `<.input field={@form[:service_env_var]} type="text" label="Service env var name" placeholder="PORT" />` in the template, following the existing pattern for `run_command` and `setup_command`.
- In `handle_event("save", ...)`, include `service_env_var: non_blank(params["service_env_var"])` in the `attrs` map so blank strings become `nil`.
- In `handle_event("validate", ...)`, drop the port-filter logic; just rebuild the form from params and assign.
- Remove the "Port definitions" section label, add-button, and per-row delete-button from the template.
- Add unique DOM IDs consistent with project form conventions (e.g., `id="project-form"` already likely exists; ensure the new input has a stable label for test selectors).

**Patterns to follow:**
- `<.input field={@form[:run_command]} ...>` already in the same template.
- `non_blank/1` helper already present for `setup_command` / `run_command`.

**Test scenarios:**
- Happy path: user fills in name, git URL, run command, and `service_env_var = "PORT"` → project persists with `service_env_var == "PORT"`.
- Happy path: user fills in name, git URL, run command, leaves `service_env_var` blank → project persists with `service_env_var == nil` (not `""`).
- Error path: user submits `service_env_var = "invalid-name"` → validation error appears on the `service_env_var` field (tested via `has_element?(view, "...service_env_var...error...")` or by matching the error copy rendered under the input). The form should not submit.
- Error path: user submits `service_env_var = "PATH"` → reserved-name validation error on the field.
- Edit: opening an existing project's form prefills `service_env_var`.
- UI: no "Port definitions" label, no add-port button, no per-row remove controls exist in the rendered HTML (regression guard against leftover code paths).

**Verification:**
- `mix test test/destila_web/live/projects_live_test.exs` passes.
- Hitting the project form in the running dev server shows a single text input for Service env var name; creating and editing a project works end-to-end.

---

- [ ] **Unit 6: Service sidebar — visibility gate + scalar-port link**

**Goal:** Render the service sidebar item only when the project is a webservice. Link to `http://localhost:<port>` (new tab) when running; no link otherwise. Hide entirely when the project has no run command, no env var, or the session has no project.

**Requirements:** R7, R9

**Dependencies:** Units 1, 2.

**Files:**
- Modify: `lib/destila_web/live/workflow_runner_live.ex`
- Test: `test/destila_web/live/service_status_sidebar_live_test.exs`

**Approach:**
- Visibility: introduce a single boolean derived in the template or as a helper, e.g., `webservice? = @project && present?(@project.run_command) && present?(@project.service_env_var)`. Wrap the entire service sidebar block in `<%= if webservice? do %> ... <% end %>`. Remove the `"disabled"` fallback branch currently at lines 917-934 (service item is simply absent for non-webservice projects).
- `service_url/2`: rewrite to match the new shape.
  - `service_url(%{service_env_var: env_var}, %{"status" => "running", "port" => port}) when is_integer(port) and is_binary(env_var) -> "http://localhost:#{port}"`
  - `service_url(_, _) -> nil`
  - Note: `env_var` is matched but not used in the URL; it's the gate for "this is a webservice" at the readerside (defensive; the outer visibility gate already ensures this). Alternatively, drop the pattern-match on project entirely once the visibility gate is trusted.
- Icon logic (green for running/starting, muted for stopped/nil) is preserved but simplified because the fallback "no run command" branch is gone.
- Link renders with `target="_blank"` and `rel="noopener noreferrer"` (already convention) when `service_url/2` returns a URL; renders as non-link span otherwise (icon + label), preserving current styling.
- Delete the old "Running service without available port shows green icon" special-case — the prompt explicitly removes it.

**Patterns to follow:**
- The existing sidebar item markup for link vs. non-link rendering (lines 858-892 in the current file).
- Existing `service_status` / `service_running?` derivation at lines 827-831.

**Test scenarios:**
- Happy path (visible webservice): project has `run_command` and `service_env_var = "PORT"` → service item renders in the sidebar.
- Hidden: project has `run_command` but no `service_env_var` → no service item element appears.
- Hidden: project has `service_env_var` but no `run_command` → no service item element.
- Hidden: session has no project → no service item element.
- Icon: service running → icon has the green class (current assertion on class name preserved).
- Icon: service stopped → icon has the muted/gray class.
- Icon: service_state is nil (but project is a webservice) → icon has muted class and item is not clickable.
- Link: running with integer `port` in service_state → `<a>` with `href="http://localhost:<port>"` and `target="_blank"`.
- No link: stopped state → item renders but is not an `<a>` (assert via selector).
- No link: nil service_state → not clickable.
- Real-time update: broadcasting a state change from stopped to running (via the existing PubSub path) flips the item to clickable with the correct port URL.
- Legacy tolerance: service_state `%{"status" => "running", "ports" => %{"PORT" => 4712}}` (missing `"port"`) → renders icon as running but item is not clickable (no URL). This is the R9 guarantee at the reader.

**Verification:**
- `mix test test/destila_web/live/service_status_sidebar_live_test.exs` passes.
- Manual: visit a session whose project has both fields set and start the service; click the link in a new tab and confirm the URL.

---

- [ ] **Unit 7: Gherkin feature updates + tag sync**

**Goal:** Replace the listed scenarios in the three feature files per the user's prompt, and update existing `@tag` annotations on tests to match.

**Requirements:** R10

**Dependencies:** Units 1–6 (so the referenced behavior is implemented before the feature file claims it).

**Files:**
- Modify: `features/project_management.feature`
- Modify: `features/service_status_sidebar.feature`
- Modify: `features/service_setup_command.feature`
- Modify (tag sync): `test/destila/projects/project_test.exs`, `test/destila/services/service_manager_test.exs`, `test/destila/workers/prepare_workflow_session_test.exs`, `test/destila_web/live/projects_live_test.exs`, `test/destila_web/live/service_status_sidebar_live_test.exs`

**Approach:**
- `features/project_management.feature`: remove the three port-definition scenarios (lines 80-86, 88-95, 97-103 in the current file). Add the three scenarios from the prompt: "Create a project with run command and a service env var", "Create a project without a service env var name", "Service env var requires a valid environment variable name". Keep the feature-description paragraph updated to mention "a service env var name" instead of "port definitions". Preserve the setup-command scenarios and all pre-port scenarios unchanged.
- `features/service_status_sidebar.feature`: replace the feature description with the one from the prompt. Replace scenarios lines 27-32, 50-55, and 57-62 per the prompt. Remove the "Running service without available port shows green icon" scenario. Keep or adjust "Service item visible when project has run_command" to the new "Service item visible when project is a webservice" wording; drop "Service item disabled when no run_command configured" and replace with the two "Service item hidden when..." scenarios from the prompt. Preserve the "Service item hidden when session has no project" scenario with the wording from the prompt.
- `features/service_setup_command.feature`: update the feature description paragraph with the new one from the prompt. Remove the "Setup sees the same port environment variables as the run command" scenario (lines 28-31). Add the two new scenarios: "Post-worktree setup runs without allocating a port" and "Start/restart allocates a port and exports the service env var for both setup and run". Keep the other scenarios; update any that reference "ports" (the "Empty setup_command behaves like nil" scenario is unchanged since it doesn't reference ports).
- Tag sync: scan all affected test files for `@tag feature:`/`@tag scenario:` pairs, update or remove references to the deleted scenarios, and add tags on new tests introduced in Units 1, 2, 3, 5, 6. Every scenario in the updated feature files should have ≥1 linked test; every test `@tag` should point at an existing scenario.

**Patterns to follow:**
- Existing scenario wording style in the three feature files.
- `@tag feature: "Service Status Sidebar", scenario: "..."` pattern already used in `test/destila_web/live/service_status_sidebar_live_test.exs`.

**Test scenarios:**
- Verify `mix test --only feature:service_status_sidebar` runs a non-empty set and all pass.
- Verify `mix test --only feature:service_setup_command` runs a non-empty set and all pass.
- Verify `mix test --only feature:project_management` runs a non-empty set and all pass.
- Grep for the deleted scenario titles in test files: no stale `@tag scenario:` references should remain.
- Grep for `port_definitions` and `"ports"` across `features/` and `test/`: no matches (Test expectation: grep assertion as part of Unit 8's precommit pass).

**Verification:**
- `grep -r "port_definitions\|\"ports\"" features test lib` returns no results (other than any intentionally legacy-tolerance test in Unit 4).

---

- [ ] **Unit 8: Final precommit pass**

**Goal:** Run `mix precommit` and address any residual warnings, formatting, or test failures before finishing.

**Requirements:** R10

**Dependencies:** Units 1–7.

**Files:**
- N/A (no code changes expected; only follow-ups triggered by the command).

**Approach:**
- Run `mix precommit` (which is `["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]` per `mix.exs`).
- Address any warnings-as-errors (most likely: unused aliases/variables if a handler was removed).
- Resolve any test failures surfaced by the cross-cutting changes.
- Re-run until clean.

**Test expectation:** none — this unit runs the existing suite and formatter; it does not introduce new tests.

**Verification:**
- `mix precommit` exits 0.

## System-Wide Impact

- **Interaction graph:**
  - `Destila.Projects.Project` → `ServiceManager` (start/stop/restart), `PrepareWorkflowSession` (post-worktree), `WorkflowRunnerLive` (sidebar gate), `ProjectFormLive` (form).
  - `ServiceManager` → `Workflows.update_workflow_session/2` (persists `service_state`), `Tmux.send_keys/2` (sends the composed shell string).
  - `AI.Tools.:service` → `ServiceManager.execute/3` (action dispatch) → returns JSON to the AI.
  - `AI.Conversation.build_service_section/1` → reads `service_state` for context injection into the AI prompt.
  - `WorkflowRunnerLive` → subscribes to PubSub updates keyed by session id; re-renders on `service_state` change.
- **Error propagation:**
  - Precondition failure in `do_start`/`do_restart` returns `{:error, reason}` → the MCP tool wraps as `"Service error: <reason>"` → surfaces to the AI verbatim.
  - Tmux failures remain wrapped in `try/rescue` blocks in the worker; worktree readiness is not blocked.
  - Startup port-timeout path is unchanged: `do_stop` is invoked, the stored state becomes `"stopped"` (with `"port"` omitted), and the error is returned up the stack.
- **State lifecycle risks:**
  - Legacy `%{"ports" => %{...}}` `service_state` records exist on disk after deploy. Every reader must tolerate a missing `"port"` key and treat it as "no URL". Readers covered: `WorkflowRunnerLive.service_url/2`, `AI.Tools` JSON transform, `AI.Conversation.build_service_section/1`. A fresh `do_start` rewrites the record cleanly.
  - `do_stop` must not crash on legacy shape: handled by reading `(ws.service_state || %{})["port"]` (absent on legacy records → not added to the output map).
- **API surface parity:** The MCP tool's JSON is a public contract with the AI. Changing `ports` → `url` is a breaking change for any cached AI behavior, but the AI consumes the tool fresh each turn; no durable contract exists beyond the in-prompt description text, which is updated in the same unit.
- **Integration coverage:** End-to-end path (form submit → changeset → DB → `do_start` → tmux → sidebar link) needs cross-layer coverage: the projects LiveView test asserts persistence; the ServiceManager test asserts state shape; the sidebar test asserts reader behavior. Together they cover the full flow.
- **Unchanged invariants:**
  - Tmux service window index remains 9.
  - `@startup_timeout_ms` (60s) and port-probe cadence unchanged.
  - `cleanup/1` still clears `service_state` to nil on archive.
  - Session archiving, worktree creation ordering, and AI session lifecycle unchanged.
  - `setup_command; run_command` semicolon-chaining preserved so setup failure does not block run.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Deployed instances have live `service_state` in the old `%{"ports" => _}` shape when this lands. | Every reader tolerates missing `"port"` and treats it as no-URL. Next `do_start`/`do_restart` rewrites to new shape. No backfill needed. |
| Dropping `port_definitions` loses configured multi-port projects. | Per prompt: acceptable. Single-migration, no backfill. Call out in commit message for visibility. |
| Removed event handlers (`add_port`, `remove_port`, `update_port`) leave orphan `phx-click` references in another template. | Grep for `"add_port"`, `"remove_port"`, `"update_port"` across `lib/destila_web/` after Unit 5; remove any orphan references. Part of Unit 8 verification. |
| Feature-test `@tag` annotations drift out of sync with the renamed scenarios. | Unit 7 explicitly includes tag sync. Running `mix test --only feature:<name>` validates coverage per feature. |
| Webservice predicate duplicated across readers diverges over time. | Key Technical Decisions mandate a single predicate (private helper or `Projects.webservice?/1`). Code review should flag duplications. |
| The MCP tool prompt doc block and the tool's `description/1` drift out of sync. | Unit 4 updates both in the same change. |

## Documentation / Operational Notes

- No separate docs update required — the in-repo feature files are the user-facing specification.
- The MCP tool's inline description text (shown to the AI) must be updated alongside the code in Unit 4.
- No rollout flags or monitoring changes: the change is synchronous at deploy. On first load post-deploy, any session with legacy `service_state` will show the service icon (if the project qualifies as a webservice) with no clickable link until the next start.

## Sources & References

- Origin: user prompt (no upstream requirements document; planning proceeded from the prompt directly).
- Related prior plans:
  - `docs/plans/2026-04-14-001-feat-project-service-management-plan.md`
  - `docs/plans/2026-04-14-003-feat-service-status-sidebar-plan.md`
  - `docs/plans/2026-04-16-002-feat-project-setup-command-plan.md`
- Core source files:
  - `lib/destila/projects/project.ex`
  - `lib/destila/services/service_manager.ex`
  - `lib/destila/workers/prepare_workflow_session.ex`
  - `lib/destila/ai/tools.ex`
  - `lib/destila/ai/conversation.ex`
  - `lib/destila_web/live/workflow_runner_live.ex`
  - `lib/destila_web/live/project_form_live.ex`
- Feature files:
  - `features/project_management.feature`
  - `features/service_status_sidebar.feature`
  - `features/service_setup_command.feature`
- Tests:
  - `test/destila/projects/project_test.exs`
  - `test/destila/services/service_manager_test.exs`
  - `test/destila/workers/prepare_workflow_session_test.exs`
  - `test/destila_web/live/projects_live_test.exs`
  - `test/destila_web/live/service_status_sidebar_live_test.exs`
