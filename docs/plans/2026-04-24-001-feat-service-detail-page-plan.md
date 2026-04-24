---
title: "feat: Service Detail Page for Workflow Sessions"
type: feat
status: active
date: 2026-04-24
---

# feat: Service Detail Page for Workflow Sessions

## Overview

Add a dedicated `/services/:id` LiveView that surfaces, for each webservice-configured workflow session, the service's current status, assigned port, run/setup commands, lifecycle controls (Start, Stop, Restart, Clear logs), and a persisted log viewer backed by `tmux pipe-pane`. The existing inline service row in `WorkflowRunnerLive`'s sidebar keeps its current behavior and gains an "Open service details" icon button that navigates to the new page.

This introduces:

- A per-service log file (`tmp/services/<session_id>.log`) written by `tmux pipe-pane`, truncated on each service start, deleted on session archive/delete.
- A per-session `LogTailer` GenServer that polls the log file and publishes deltas on a new `"service:<session_id>"` PubSub topic. Status transitions (`starting → running → stopped`) are also broadcast on that topic.
- Reuse of the existing `ServiceManager.execute/3` contract — no new async patterns.

## Problem Frame

Today a session's service can be started/stopped from a single compact sidebar row with no visibility into logs, no ability to restart from the UI, and no dedicated space for operational context. Users debugging a failing service must `tmux attach` out-of-band. The detail page gives the service a first-class home consistent with the rest of the session navigation model (session detail, terminal, AI session detail), while keeping the sidebar row compact.

## Requirements Trace

- **R1.** `/services/:id` renders status (running | starting | stopped), assigned port, `http://localhost:<port>` link (new tab) when running, `run_command`, and `setup_command` when configured.
- **R2.** `/services/:id` returns 404 for unknown session, session with no project, and project where `webservice?/1` is false (no `run_command` or no `service_env_var`).
- **R3.** `/services/:id` exposes Start (when stopped), Stop + Restart (when running), and Clear logs (always).
- **R4.** Service logs are captured via `tmux pipe-pane` to `tmp/services/<session_id>.log`, truncated on each new start, deleted on session archive/delete.
- **R5.** Logs render on mount from file contents and update live as new bytes arrive. Logs survive a page reload and survive service stop; a new start replaces them.
- **R6.** Start and Restart use the existing async `Task` pattern in `WorkflowRunnerLive`; the LiveView process never blocks on the up-to-60s port wait.
- **R7.** The workflow runner sidebar gains an "Open service details" icon button that `<.link navigate={~p"/services/#{session.id}"}>` to the new page, and still hides the service row entirely when the project is not a webservice.
- **R8.** The existing sidebar service row continues to reflect service state changes live (must not regress).
- **R9.** `features/service_status_sidebar.feature` gains the navigation scenario and a new `features/service_detail_page.feature` covers the new page; every scenario has at least one linked test via `@tag feature:/scenario:`.

## Scope Boundaries

- **Out of scope:** extracting the inline sidebar service row into a shared function component (the existing DOM ids are load-bearing for tests; keep the row inline and only add the new icon button).
- **Out of scope:** authentication/authorization changes (the codebase has no `current_scope` yet — the page follows existing unauthenticated conventions).
- **Out of scope:** changing log capture to a structured / parsed format. Raw stdout/stderr text only.
- **Out of scope:** WebSocket/streaming log implementation via an xterm.js hook (uses LiveView streams of log lines for consistency with project patterns).
- **Out of scope:** changing `ServiceManager.execute/3`'s public shape or introducing a new async supervision model.
- **Out of scope:** log rotation, size limits, or compression. Files grow unbounded within a run; truncation on next start bounds growth per-run.

## Context & Research

### Relevant Code and Patterns

- `lib/destila/services/service_manager.ex` — `execute/3`, `do_start/2`, `do_stop/1`, `do_restart/2`, `cleanup/1`. Constants: `@service_window 9`, `@startup_timeout_ms 60_000`. Start currently sequences `Tmux.ensure_session → Tmux.kill_window → Tmux.new_window → Tmux.send_keys`; pipe-pane must be inserted between `new_window` and `send_keys`.
- `lib/destila/terminal/tmux.ex` — shell-out wrappers over `tmux`. Has `new_window/2`, `send_keys/2`, `kill_window/1`, `window_exists?/1`, `term_panes/1`, and `escape_shell/1`. **No `pipe_pane` today — add it.**
- `lib/destila_web/live/workflow_runner_live.ex:245-261` — existing async start pattern: fire-and-forget `Task.start/1` wrapping `ServiceManager.execute("start", opts)` with a `try/rescue Logger.error(...)` block. Stop is synchronous. Reuse this pattern verbatim for the detail page.
- `lib/destila_web/live/workflow_runner_live.ex:975-1061` — inline sidebar service row with existing DOM ids `#service-status-item`, `#service-status-link`, `#service-start-button`, `#service-stop-button`. Add the new icon button here without touching those ids.
- `lib/destila/pub_sub_helper.ex` — existing topic helpers. Precedent for per-session topics: `ai_stream_topic/1` → `"ai_stream:<ws_id>"` and Terminal.Server's `"terminal:<ws_id>"`. Add `service_topic/1 → "service:<ws_id>"` here.
- `lib/destila/workflows.ex:155-161, 220-225, 285-309` — `get_workflow_session/1` returns `nil`; `get_workflow_session!/1` raises `Ecto.NoResultsError` (Plug.Exception → HTTP 404). `update_workflow_session/2` broadcasts `{:workflow_session_updated, ws}` on `"store:updates"`. `archive_workflow_session/1` and `delete_workflow_session/1` call `ServiceManager.cleanup/1` when `ws.service_state` is present — extend cleanup to drop the log file and stop the tailer.
- `lib/destila_web/router.ex` — single `:browser` pipeline, no `live_session`, no `current_scope`. New route sits alongside `live "/sessions/:id/terminal", TerminalLive`.
- `lib/destila_web/components/layouts.ex:1-22` — `Layouts.app` accepts `flash` and `page_title` only. **No `current_scope` assign exists in this codebase**; the CLAUDE.md Phoenix 1.8 guidance assumes scope-based auth that has not been set up here. Follow codebase convention.
- `lib/destila/workflows/session.ex` — session id is `:binary_id` (UUID string). Route param will be a string.
- `lib/destila/projects/project.ex:45-47` — `Project.webservice?/1` definition.
- `lib/destila/application.ex:10-23` — OTP children. Add `Destila.Services.LogTailerRegistry` (Registry) and `Destila.Services.LogTailerSupervisor` (DynamicSupervisor) here.
- `test/destila_web/live/service_status_sidebar_live_test.exs` — canonical pattern for LiveView tests with Claude stubs, session/project factories via `Workflows.insert_workflow_session/1` + `Projects.create_project/1`, and live-update simulation via `send(view.pid, {:workflow_session_updated, updated_ws})`.
- `lib/destila_web/live/terminal_live.ex` — precedent for subscribing to a per-session topic (`"terminal:<ws_id>"`) and receiving `{:terminal_output, data}` chunks in `handle_info/2`. The log viewer uses the same shape with `{:service_log, chunk}` but renders via LiveView streams rather than an xterm.js hook.

### Institutional Learnings

- `docs/solutions/2026-04-21-erlexec-vs-expty-evaluation.md` — tangentially relevant: flags **tmux client teardown leaks** and **exit-reason normalization** as areas to watch when adding tmux-backed service supervision. Mitigation in this plan: `LogTailer` uses only `File.open` + polling (no tmux client attachment), and all lifecycle transitions go through `ServiceManager`, which already issues `term_panes` + `kill_window` on stop.

### External References

- Not used. Phoenix 1.8 / LiveView 1.1 patterns are well-established in the codebase; `tmux pipe-pane` semantics are stable and documented in the tmux man page (`-o` toggles, omit to always open).

## Key Technical Decisions

- **PubSub topic: `"service:<session_id>"` carries both status transitions and log deltas.** Rationale: the user prompt explicitly requests one dedicated topic; matching the per-session `"terminal:<ws_id>"` precedent keeps naming consistent. The sidebar keeps using the existing `"store:updates"` stream — no subscribe change there — so R8 holds without coupling the sidebar to the new topic.
- **Sidebar reads status via the existing `{:workflow_session_updated, ws}` flow; the detail page reads status via `"service:<session_id>"`.** Rationale: zero regression risk on the sidebar. `ServiceManager` broadcasts status on the new topic *in addition to* the existing `update_workflow_session` flow.
- **Log capture strategy: `tmux pipe-pane -t <target>` writing to `tmp/services/<session_id>.log` via `sh -c`.** Rationale: simpler than an in-VM PTY capture and matches the feature description verbatim. Truncation-on-start uses `File.write!(log_path, "")` before `new_window` (so pipe-pane appends to a fresh file). The shell command is `cat >> <escape_shell(absolute_log_path)>`.
- **Log tail via GenServer polling, not `inotify` / `fs`.** Rationale: zero new dependencies. A `LogTailer` opens the file read-only, remembers its position, and polls every 250 ms; on each tick it reads new bytes, broadcasts `{:service_log, chunk}`, advances position, and detects external truncation (size < position) by resetting. Simpler than inotify and sufficient for interactive log volumes.
- **LogTailer lifecycle: one process per active service run, started by `ServiceManager.do_start/2`, stopped by `do_stop/1`.** Rationale: tailer exists only while bytes may arrive. Page-reload-after-stop reads the file directly on mount — no tailer needed to show old logs.
- **Log rendering: LiveView stream of line structs (`%{id: integer, text: string}`).** Rationale: matches `lib/destila_web/live/projects_live.ex` precedent and keeps memory bounded server-side; tests can target individual lines by id. Chunks arriving mid-line are buffered in a `:log_buffer` assign until a newline flushes them to the stream.
- **404 mechanism: raise `Ecto.NoResultsError` from `mount/3`.** Rationale: `Ecto.NoResultsError` implements `Plug.Exception` with status 404, so Phoenix's error view returns a real 404 for the HTTP mount (matching the Gherkin). Using `Repo.get!`/`get_workflow_session!` already raises this shape for unknown ids; the plan raises the same exception for the webservice-precondition branches for consistency. This is a new 404 style for this codebase (sibling LiveViews redirect with a flash) — accepted deviation justified by the explicit Gherkin requirement.
- **Restart on the detail page reuses the existing async `Task.start/1` pattern.** Rationale: explicit user-prompt constraint — do not invent a new async pattern.
- **No `current_scope` assign in `Layouts.app`.** Rationale: the codebase does not yet define scopes and all existing LiveViews omit it. Deviation from the user prompt's `<Layouts.app flash={@flash} current_scope={@current_scope}>` wording is intentional to match the rest of the app.

## Open Questions

### Resolved During Planning

- **How is the sidebar's live update preserved?** → Keep `ServiceManager` broadcasting through `update_workflow_session/2` (which fires `{:workflow_session_updated, ws}` on `"store:updates"`, which `WorkflowRunnerLive` already handles). Additionally emit `"service:<id>"` broadcasts for the detail page. No sidebar subscribe changes.
- **Should the LogTailer re-broadcast existing file content on startup?** → No. The LiveView reads the file directly on mount; the tailer only broadcasts deltas after startup. Avoids double-rendering on page mount.
- **How is "Clear logs" implemented?** → A new `ServiceManager.clear_logs(ws)` (or equivalent in the log helper module) truncates the file and broadcasts `{:service_logs_cleared, session_id}` on `"service:<id>"`. ServiceDetailLive resets its stream in response.
- **What about shell escaping in `pipe-pane`?** → Use `Tmux.escape_shell/1` on the absolute log path; UUID session ids never contain special characters but `tmp/services/...` paths expanded from `File.cwd!/0` can contain spaces on some machines.
- **How does the detail page know the current status on initial HTTP mount?** → `service_state` is persisted on the session row; read it during mount. Live updates from then on come from `"service:<id>"`.

### Deferred to Implementation

- **Exact poll interval and read-chunk size for LogTailer.** Start at 250 ms / `:all` (read all new bytes). Tune only if stress-tested with a high-volume service reveals lag or starvation.
- **Whether `File.read!` on mount should be line-split server-side or streamed via `File.stream!`.** Start with `File.read!` + `String.split(contents, "\n")`; reconsider only if logs grow large enough to stall mount (unbounded file size is bounded by truncation-on-start in practice).
- **Whether `pipe-pane` requires the `-o` (toggle-only-if-not-open) flag.** Since `kill_window` precedes `new_window` we always have a fresh pane with no pipe active — `-o` is unnecessary but harmless; pick during implementation based on the simplest tmux invocation that works.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```
                   ┌──────────────────────────────────────────┐
                   │         ServiceDetailLive (browser)       │
                   │  · stream(:log_lines)                     │
                   │  · assigns: :workflow_session, :project,  │
                   │    :service_state, :log_buffer            │
                   └──────────────────┬───────────────────────┘
                                      │ subscribe
                                      ▼
                        ┌───────────────────────────────┐
                        │ PubSub "service:<session_id>" │
                        │  {:service_status, state}     │
                        │  {:service_log, chunk}        │
                        │  {:service_logs_cleared, id}  │
                        └──┬─────────────────────┬──────┘
             broadcasts    │                     │  broadcasts
                           │                     │
            ┌──────────────┴──────────┐   ┌──────┴──────────────┐
            │ ServiceManager          │   │ LogTailer (GenServer)│
            │  · do_start → truncate  │   │  · File.open(log)    │
            │    log, start tailer,   │   │  · poll every 250ms  │
            │    pipe-pane, send_keys │   │  · read new bytes    │
            │  · do_stop → stop       │   │  · broadcast chunk   │
            │    tailer, keep file    │   │  · reset on truncate │
            │  · cleanup → stop       │   └──────────┬───────────┘
            │    tailer, delete file  │              │ reads
            └────────┬────────────────┘              ▼
                     │ writes via                ┌────────────────────┐
                     │ tmux pipe-pane            │ tmp/services/      │
                     ▼                           │  <session_id>.log  │
            ┌───────────────────────────────────▶│                    │
            │ tmux pane in window 9              └────────────────────┘
            │ (service_target ws-<id>:9)
            └────────────────────────────────────
```

Status and log deltas arrive on the same topic; consumers pattern-match. On mount the LiveView reads the current file contents directly (so logs survive page reload and service stop without needing the tailer to be running).

## Implementation Units

- [ ] **Unit 1: `Tmux.pipe_pane/2` and service log/topic helpers**

**Goal:** Add the low-level tmux primitive and a small helper surface for log paths and PubSub topic naming.

**Requirements:** R4, R5.

**Dependencies:** None.

**Files:**
- Modify: `lib/destila/terminal/tmux.ex` (add `pipe_pane/2`)
- Modify: `lib/destila/pub_sub_helper.ex` (add `service_topic/1`, `broadcast_service_status/2`, `broadcast_service_log/2`, `broadcast_service_logs_cleared/1`)
- Create: `lib/destila/services/logs.ex` (single module holding `log_path/1`, `log_dir/0`, and `ensure_log_dir/0`; keeps path logic out of `ServiceManager`)
- Test: `test/destila/services/logs_test.exs`

**Approach:**
- `Tmux.pipe_pane/2` shells out to `tmux pipe-pane -t <target> <shell_command>`. Pass the command as a single argv argument (tmux invokes `sh -c` internally).
- `Destila.Services.Logs.log_path/1` returns the absolute path `Path.join([File.cwd!(), "tmp/services", "#{ws_id}.log"])`. Use the absolute path so tmux pipe-pane (which runs under the service's cwd) writes to the right place.
- `Destila.Services.Logs.ensure_log_dir/0` does `File.mkdir_p!(log_dir())`.
- `PubSubHelper.service_topic/1` returns `"service:#{session_id}"`. Broadcasts use `Phoenix.PubSub.broadcast/3` against `Destila.PubSub`.

**Patterns to follow:**
- Existing `Tmux.new_window/2` / `send_keys/2` / `kill_window/1` for argv structure.
- Existing `PubSubHelper.ai_stream_topic/1` for topic helper shape.

**Test scenarios:**
- Happy path: `Logs.log_path(ws_id)` returns an absolute path ending in `tmp/services/<ws_id>.log`.
- Happy path: `Logs.ensure_log_dir/0` creates `tmp/services/` idempotently.
- `Tmux.pipe_pane/2` itself is covered by integration in Unit 3 (following the no-unit-test precedent for the rest of the `Tmux` module).

**Verification:**
- `mix compile --warnings-as-errors` succeeds.
- `mix test test/destila/services/logs_test.exs` passes.

- [ ] **Unit 2: `LogTailer` GenServer + DynamicSupervisor + Registry**

**Goal:** One GenServer per active service run, polling the log file and broadcasting deltas on `"service:<session_id>"`.

**Requirements:** R4, R5.

**Dependencies:** Unit 1.

**Files:**
- Create: `lib/destila/services/log_tailer.ex`
- Create: `lib/destila/services/log_tailer_supervisor.ex` (DynamicSupervisor)
- Modify: `lib/destila/application.ex` (add `Registry` named `Destila.Services.LogTailerRegistry` and the new DynamicSupervisor as children)
- Test: `test/destila/services/log_tailer_test.exs`

**Approach:**
- `LogTailer.start_link(ws_id)` registered via `{:via, Registry, {Destila.Services.LogTailerRegistry, ws_id}}` so `ServiceManager` can look it up without tracking pids.
- State: `%{ws_id, log_path, io, position, poll_ms}`. `init/1` ensures the log dir exists, opens the file read-only binary, seeks to start (position 0 — the file was just truncated by `ServiceManager`), and schedules a poll.
- Poll loop: `File.stat!(log_path)`. If `size < position`, file was externally truncated — close and reopen, reset position to 0. If `size > position`, read the delta bytes with `IO.binread(io, size - position)`, broadcast `{:service_log, chunk}`, advance position. Always reschedule with `Process.send_after(self(), :poll, poll_ms)`.
- `terminate/2` closes the io device. Stopping via `DynamicSupervisor.terminate_child/2`.
- `LogTailer.start_for(ws_id)` / `LogTailer.stop_for(ws_id)` public API used by `ServiceManager`. `start_for/1` is idempotent (no-op if already running).

**Patterns to follow:**
- `lib/destila/terminal/server.ex` (GenServer per-session pattern, Registry-backed).
- `Task.async_stream` not applicable here — this is a single long-lived consumer, not a concurrent batch.

**Test scenarios:**
- Happy path: write bytes to the log file → tailer broadcasts `{:service_log, bytes}` on `"service:<ws_id>"` within the poll interval.
- Edge case: file truncated externally (size drops below position) → tailer resets and subsequent appends broadcast from the start.
- Happy path: `LogTailer.stop_for/1` terminates the process and closes the file handle (verify via `Process.alive?/1` after a `Process.monitor` DOWN assertion, per CLAUDE.md test guidelines).
- Edge case: `start_for/1` called twice for the same `ws_id` — second call is a no-op; only one registered pid.
- Happy path: tailer opens an empty file on init and broadcasts nothing until bytes are written (proves no double-rendering of existing file contents).

**Verification:**
- All scenarios pass without `Process.sleep` (use `Process.monitor` + `:sys.get_state` for synchronization).
- DynamicSupervisor and Registry show up in `:observer` / `Destila.Application.start/2` wiring.

- [ ] **Unit 3: `ServiceManager` integration — pipe-pane wiring, tailer lifecycle, cleanup, log ops, status broadcasts**

**Goal:** Plug log capture and tailing into every `ServiceManager` lifecycle path and add first-class log clearing + status broadcasts.

**Requirements:** R3 (Clear logs), R4, R5, R6, R8.

**Dependencies:** Units 1, 2.

**Files:**
- Modify: `lib/destila/services/service_manager.ex`
- Test: `test/destila/services/service_manager_test.exs` (extend existing file if present, otherwise create)

**Approach:**
- `do_start/2`: immediately before `Tmux.new_window(target, ...)`, call `Logs.ensure_log_dir/0` and `File.write!(Logs.log_path(ws.id), "")` to truncate. Stop any existing tailer via `LogTailer.stop_for(ws.id)`. After `Tmux.new_window`, call `Tmux.pipe_pane(target, "cat >> #{Tmux.escape_shell(Logs.log_path(ws.id))}")`. Then start a fresh tailer via `LogTailer.start_for(ws.id)`. Continue with `Tmux.send_keys`. Wrap each `update_workflow_session(%{service_state: ...})` with a parallel `PubSubHelper.broadcast_service_status(ws.id, state)` so the detail page sees status transitions on the new topic.
- `do_stop/1`: call `LogTailer.stop_for(ws.id)` (idempotent) before or after `term_panes`. Do **not** touch the log file — previous run's logs must remain. Broadcast the stopped state on `"service:<id>"` after `update_workflow_session`.
- `do_restart/2`: unchanged (stop + start). The new behavior is inherited: stop tears down the tailer; start truncates, re-pipes, and starts a new tailer.
- `cleanup/1`: after `Tmux.kill_window`, add `LogTailer.stop_for(ws.id)` and `File.rm(Logs.log_path(ws.id))` (use `File.rm` not `rm!` — tolerate missing file).
- Add `ServiceManager.clear_logs(ws)` public function: truncates the file via `File.write!(path, "")` and calls `PubSubHelper.broadcast_service_logs_cleared(ws.id)`. Return `:ok`. (Does not restart the tailer — the existing tailer detects truncation via the polling path already; if the service is stopped, no tailer is running and the file is simply empty on next mount.)
- Keep the `@webservice_precondition_error` and existing precondition branches untouched.

**Patterns to follow:**
- Existing `do_start/2` structure — keep all Logger calls.
- `PubSubHelper` existing broadcast style (`broadcast_event/2`).

**Test scenarios:**
- Happy path: `execute(ws, "start", ...)` — stubbed/monkey-patched `Tmux` module records calls, verify the sequence `ensure_session → kill_window → new_window → pipe_pane → send_keys` and that the log file was truncated beforehand. (Use Mimic — already a dep.)
- Happy path: after start, a `LogTailer` is registered for `ws.id`.
- Happy path: after `execute(ws, "stop")`, the `LogTailer` for `ws.id` is no longer registered; the log file still exists with prior content.
- Happy path: `execute(ws, "restart")` — log file truncated on the start leg; tailer replaced.
- Happy path: `cleanup/1` deletes the log file, stops the tailer, and clears `service_state`.
- Happy path: `clear_logs/1` truncates the file and broadcasts `{:service_logs_cleared, ws_id}` on `"service:<ws_id>"`.
- Integration: subscribing to `"service:<ws_id>"` before calling `execute(ws, "start")` receives `{:service_status, %{"status" => "starting", ...}}` (and, if the port opens, `{:service_status, %{"status" => "running", ...}}`). Use a fake port probe or `ServiceManager` short-circuit for the running transition; otherwise assert only on the starting broadcast.
- Error path: `cleanup/1` when the log file doesn't exist — does not raise.

**Verification:**
- All tests pass with `mix test test/destila/services/service_manager_test.exs`.
- No regressions in `test/destila_web/live/service_status_sidebar_live_test.exs`.

- [ ] **Unit 4: Sidebar "Open service details" icon button**

**Goal:** Add a navigation affordance from `WorkflowRunnerLive`'s sidebar service row to the new detail page, without regressing existing DOM ids.

**Requirements:** R7.

**Dependencies:** Unit 5 (route must exist before `~p"/services/#{ws.id}"` compiles) — sequence Unit 4 after Unit 5 or add the route first.

**Files:**
- Modify: `lib/destila_web/live/workflow_runner_live.ex` (template only, around line 1041)
- Modify: `test/destila_web/live/service_status_sidebar_live_test.exs`

**Approach:**
- Inside the existing `<%= if @project && Destila.Projects.Project.webservice?(@project) do %>` block, insert a `<.link navigate={~p"/services/#{@workflow_session.id}"} id="service-details-link" aria-label="Open service details" title="Open service details">` wrapping an `<.icon name="hero-arrow-top-right-on-square-micro" />` sized to match the existing start/stop button (`size-5` container, `size-3.5` icon).
- Place the link between the URL label and the start/stop button so the row layout remains `[status-icon] [label] [details-link] [start/stop]`. Do not change the existing ids `#service-status-item`, `#service-status-link`, `#service-start-button`, `#service-stop-button`.
- Update `features/service_status_sidebar.feature` (in Unit 6) with the new scenario; this unit only adds the test assertion.

**Patterns to follow:**
- Existing `<.link navigate={~p"/sessions/#{ws.id}/terminal"}>` usage nearby in the same file.
- CLAUDE.md class-list syntax for any conditional Tailwind classes.

**Test scenarios:**
- Happy path: when the project is a webservice, `#service-details-link` is rendered and its `href` equals `~p"/services/#{ws.id}"`.
- Edge case: when the project is not a webservice, `#service-details-link` is not rendered (piggybacks on the existing hide logic).

**Verification:**
- `mix test test/destila_web/live/service_status_sidebar_live_test.exs` passes.
- Manual smoke: clicking the icon navigates to `/services/:id`.

- [ ] **Unit 5: Route + `ServiceDetailLive` LiveView**

**Goal:** The page itself — mount, assigns, lifecycle events, log rendering, and template.

**Requirements:** R1, R2, R3, R5, R6, R8.

**Dependencies:** Units 1, 2, 3.

**Files:**
- Modify: `lib/destila_web/router.ex` (add `live "/services/:id", ServiceDetailLive`)
- Create: `lib/destila_web/live/service_detail_live.ex`
- Test: `test/destila_web/live/service_detail_live_test.exs`

**Approach:**

*Route.* Add `live "/services/:id", ServiceDetailLive` in the existing `scope "/", DestilaWeb` block, alongside the other `/sessions` routes.

*Mount.*
1. `id = params["id"]`.
2. `workflow_session = Workflows.get_workflow_session(id)`. If `nil`, raise `Ecto.NoResultsError, queryable: Destila.Workflows.Session`.
3. `project = workflow_session.project_id && Projects.get_project(workflow_session.project_id)`. If `nil`, raise `Ecto.NoResultsError, queryable: Destila.Projects.Project`.
4. `unless Project.webservice?(project), do: raise Ecto.NoResultsError, queryable: Destila.Projects.Project` — the 404-for-non-webservice branch.
5. If `connected?(socket)`: `Phoenix.PubSub.subscribe(Destila.PubSub, PubSubHelper.service_topic(id))`. Also subscribe to `"store:updates"` so the session/project can be refetched on updates (consistent with `WorkflowRunnerLive`).
6. Resolve `worktree_path` the same way `WorkflowRunnerLive` does — call `AI.get_ai_session_for_workflow(id)` and assign its `worktree_path` (may be `nil`).
7. Read initial log contents via `File.read(Logs.log_path(id))` → `{:ok, contents} | {:error, :enoent}`. Split by `"\n"`, drop trailing empty, build `%{id: i, text: line}` structs with a monotonically increasing integer id. Initialize `stream(:log_lines, lines, reset: true)` and assign `:next_log_id` as the next integer.
8. Buffered-chunk state: `:log_buffer` string assign for partial-line chunks that arrive without a newline.
9. Derive an initial `service_state` assign from `workflow_session.service_state || %{"status" => "stopped"}`.

*Status + log handling.*
- `handle_info({:service_status, state}, socket)` → assign `:service_state` with the map.
- `handle_info({:service_log, chunk}, socket)` → append `chunk` to `:log_buffer`; split buffer on `"\n"` — everything up to the last newline becomes new stream items (`stream_insert(:log_lines, %{id: next, text: line}, at: -1)` for each), the trailing partial stays in `:log_buffer`.
- `handle_info({:service_logs_cleared, ^id}, socket)` → `stream(:log_lines, [], reset: true)`, reset `:log_buffer` and `:next_log_id`.
- `handle_info({:workflow_session_updated, updated_ws}, socket)` when `updated_ws.id == id` → refetch and update `:workflow_session` / `:service_state` (covers the fallback where a sidebar action changes state while the page is open).

*Events.*
- `handle_event("start_service", _, socket)` → fire-and-forget `Task.start/1` wrapping `ServiceManager.execute(ws, "start", worktree_path: ...)` with `try/rescue Logger.error(...)`. Copy the exact pattern from `workflow_runner_live.ex:249-261`.
- `handle_event("stop_service", _, socket)` → synchronous `ServiceManager.execute(ws, "stop")`; on `{:error, reason}`, `put_flash(:error, ...)`.
- `handle_event("restart_service", _, socket)` → fire-and-forget `Task.start/1` wrapping `ServiceManager.execute(ws, "restart", ...)`.
- `handle_event("clear_logs", _, socket)` → `ServiceManager.clear_logs(ws)`. The incoming `{:service_logs_cleared, ...}` message drives the stream reset — do not reset the stream in-line in the event handler (single source of truth).

*Template (HEEx).*
- Wrap with `<Layouts.app flash={@flash} page_title={@page_title}>` (no `current_scope`; follow codebase convention).
- Header: session title + a `<.link navigate={~p"/sessions/#{@workflow_session.id}"}>Back to session</.link>` (`id="back-to-session-link"`).
- Status card: status text (`@service_state["status"]`), port + external `<a href="http://localhost:{@service_state["port"]}" target="_blank" rel="noopener noreferrer" id="service-url-link">…</a>` when running (and port present).
- Commands: `run_command` (always rendered for a webservice), `setup_command` (only when non-blank). Use `<code phx-no-curly-interpolation>` blocks if the commands include `{PORT}` placeholders.
- Buttons (unique DOM ids): `#start-service-button`, `#stop-service-button`, `#restart-service-button`, `#clear-logs-button`. Conditional rendering:
  - Stopped (or `nil`): show `#start-service-button`, show `#clear-logs-button`. Hide Stop/Restart.
  - Starting: show `#stop-service-button`, show `#clear-logs-button`. Hide Start/Restart (or show disabled variants — keep simple: show Stop + Clear logs only).
  - Running: show `#stop-service-button`, `#restart-service-button`, `#clear-logs-button`. Hide Start.
- Log viewer: `<div id="service-logs" phx-update="stream" class="font-mono text-xs whitespace-pre-wrap ..."><div :for={{dom_id, line} <- @streams.log_lines} id={dom_id}>{line.text}</div></div>`. Include a `<div class="hidden only:block" id="service-logs-empty">No logs yet.</div>` inside the stream container for the empty state (per CLAUDE.md stream-empty-state pattern).

**Patterns to follow:**
- `lib/destila_web/live/workflow_runner_live.ex:36-46` (mount subscribe pattern).
- `lib/destila_web/live/workflow_runner_live.ex:245-261` (async Task pattern — literally copy).
- `lib/destila_web/live/workflow_runner_live.ex:496-536` (handle_info workflow_session_updated refetch pattern).
- `lib/destila_web/live/terminal_live.ex:17-19` (per-session topic subscribe).
- CLAUDE.md LiveView streams empty-state pattern (`class="hidden only:block"`).

**Test scenarios:**
- **Happy path (R1) — running service renders port, URL, commands:** set `service_state = %{"status" => "running", "port" => 4000, "run_command" => "mix phx.server", "setup_command" => "mix deps.get"}`; `live(conn, ~p"/services/#{ws.id}")`; assert `has_element?(view, ~s|#service-url-link[href="http://localhost:4000"][target="_blank"]|)`, assert the `run_command` text appears, assert the `setup_command` text appears.
- **Happy path (R1) — setup_command hidden when blank:** create project with `setup_command: nil`; assert the setup block is not rendered (target via `#setup-command-block`).
- **Happy path (R3) — stopped shows Start, hides Stop/Restart/URL:** `service_state = %{"status" => "stopped"}` (or `nil`); assert `has_element?(view, "#start-service-button")`, `refute has_element?(view, "#stop-service-button")`, `refute has_element?(view, "#restart-service-button")`, `refute has_element?(view, "#service-url-link")`.
- **Happy path (R3) — running shows Stop + Restart, hides Start:** status `"running"`; assert the inverse.
- **Happy path (R3) — Clear logs always present:** assert `has_element?(view, "#clear-logs-button")` in both stopped and running states.
- **Happy path (R6) — Start click spawns async Task:** Mimic `ServiceManager.execute/3` to return `{:ok, ...}` after a delay; `view |> element("#start-service-button") |> render_click()`; assert LiveView process did not block (test would hang if sync).
- **Happy path — Stop click calls ServiceManager synchronously:** Mimic `ServiceManager.execute(_, "stop", _)` → `{:ok, stopped_state}`; click → assert called once with `"stop"`.
- **Happy path — Restart click calls ServiceManager via Task with `"restart"`:** Mimic → `{:ok, ...}`; click; assert call.
- **Happy path (R5) — initial log contents rendered on mount:** pre-seed the file with `"line one\nline two\n"`, mount, assert `has_element?(view, "#service-logs", "line one")` and `"line two"`.
- **Happy path (R5) — live log chunk appends:** mount with empty log; `send(view.pid, {:service_log, "hello\n"})`; assert the line appears in `#service-logs`.
- **Happy path (R5) — partial chunk buffered until newline:** `send(view.pid, {:service_log, "par"})`; assert no new line in `#service-logs`; `send(view.pid, {:service_log, "tial\n"})`; assert `"partial"` appears as one line.
- **Happy path (R5) — logs_cleared empties the stream:** pre-seed file + mount; `send(view.pid, {:service_logs_cleared, ws.id})`; assert `#service-logs-empty` visible and no line elements.
- **Happy path (R5) — logs survive page reload:** simulate by writing to file, mounting, stopping service (state change), re-mounting → log lines still appear.
- **Happy path — back link present:** `has_element?(view, ~s|#back-to-session-link[href="/sessions/#{ws.id}"]|)`.
- **Integration (R8) — sidebar still updates live:** existing sidebar tests already cover this via `{:workflow_session_updated, ws}` broadcasts; do not duplicate here, but add a ServiceDetailLive assertion that `{:workflow_session_updated, updated_ws}` triggers a status update on the detail page (proves double-subscribe works).
- **Error path (R2) — 404 for unknown id:** `assert_error_sent 404, fn -> live(conn, ~p"/services/#{Ecto.UUID.generate()}") end`.
- **Error path (R2) — 404 for session with no project:** create session with `project_id: nil`; `assert_error_sent 404, ...`.
- **Error path (R2) — 404 for project without run_command:** create project with `run_command: nil, service_env_var: "PORT"`; `assert_error_sent 404, ...`.
- **Error path (R2) — 404 for project without service_env_var:** create project with `run_command: "x", service_env_var: nil`; `assert_error_sent 404, ...`.

Each scenario gets a `@tag feature: "service_detail_page", scenario: "<Gherkin scenario title>"` matching the feature file created in Unit 6.

**Verification:**
- `mix test test/destila_web/live/service_detail_live_test.exs` passes.
- `mix test --only feature:service_detail_page` runs exactly the scenarios from the feature file.
- Manual smoke: the page loads, shows logs, Start/Stop/Restart/Clear logs work end-to-end against a real session.

- [ ] **Unit 6: Feature files**

**Goal:** Feature-file documentation and `@tag` linkage for the new scenarios.

**Requirements:** R9.

**Dependencies:** None (can be done at any point, but conceptually aligned with Units 4 and 5).

**Files:**
- Modify: `features/service_status_sidebar.feature` (append the navigation scenario exactly as specified in the user prompt)
- Create: `features/service_detail_page.feature` (populate with the Gherkin from the user prompt verbatim)

**Approach:**
- Paste the scenarios from the user prompt. Keep the existing structure of the file. The `@tag` references in Units 4 and 5 must match scenario titles exactly.

**Patterns to follow:**
- Existing `.feature` files (`service_status_sidebar.feature`, `service_setup_command.feature`).

**Test expectation:** none — pure documentation. Scenario coverage is enforced by `@tag` annotations on tests in Units 4 and 5.

**Verification:**
- `mix test --only feature:service_detail_page` returns tests from the new feature file.
- `mix test --only "scenario:Service sidebar exposes a link to the service detail page"` runs the new sidebar scenario.

## System-Wide Impact

- **Interaction graph:**
  - `ServiceManager.do_start/2` / `do_stop/1` / `cleanup/1` now call `LogTailer.start_for/1` / `stop_for/1` and touch files under `tmp/services/`. Any future caller of these functions inherits the new behavior automatically.
  - `Destila.Application`'s supervision tree gains two new children (`LogTailerRegistry`, `LogTailerSupervisor`). No existing child depends on them, so ordering does not matter.
  - `Workflows.archive_workflow_session/1` and `delete_workflow_session/1` already gate on `ws.service_state`; no change required — `cleanup/1` is called and silently handles missing tailer/file.
  - `WorkflowRunnerLive` sidebar adds one `<.link navigate={...}>`; event handlers unchanged.
- **Error propagation:**
  - `LogTailer` crashes are contained by the `DynamicSupervisor` (`restart: :temporary` — tailer only needs to run while the service runs; on crash the user can restart the service to get logs back).
  - `File.rm/1` in `cleanup/1` intentionally uses the non-bang variant to tolerate a missing file.
  - `Tmux.pipe_pane/2` failures are non-fatal — they still leave the service running; loss of logs is degraded but not broken behavior.
- **State lifecycle risks:**
  - **Log file growth within a run is unbounded.** Mitigation: truncation on next start. Outside of "run indefinitely without restarting" there is no concern. Document in code comment; no automatic rotation.
  - **Tailer + file handle leak if `stop_for/1` is not called.** Mitigation: `stop_for/1` is called from `do_stop/1` and `cleanup/1`; `DynamicSupervisor` child is `:temporary` so orphaned processes die naturally if the parent crashes.
  - **Concurrent broadcast ordering.** Status and log messages on the same topic may interleave. The LiveView handles each message type independently; no ordering dependency exists between them.
- **API surface parity:** none. `ServiceManager.execute/3`'s external contract does not change. The only new public function is `ServiceManager.clear_logs/1`.
- **Integration coverage:** Unit 3 integration tests verify the tmux-call sequence + tailer wiring; Unit 5 integration tests verify PubSub → stream rendering end-to-end.
- **Unchanged invariants:**
  - Sidebar DOM ids `#service-status-item`, `#service-status-link`, `#service-start-button`, `#service-stop-button` remain intact.
  - `Layouts.app` signature remains `flash`/`page_title` — no scope assigns introduced.
  - `Workflows.update_workflow_session/2` → `"store:updates"` broadcast flow is unchanged; sidebar continues to receive live updates through it.
  - `ServiceManager.execute/3` return shape `{:ok, service_state} | {:error, reason}` is unchanged.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `tmp/services/` not gitignored → log files checked in. | Verify `.gitignore` already ignores `tmp/` (standard Phoenix); if not, add an entry during Unit 1. |
| `tmux pipe-pane` silently drops output when the log path is unwritable. | `Logs.ensure_log_dir/0` called before `pipe_pane` in `do_start/2`; use absolute path. |
| `LogTailer` poll interval (250 ms) introduces perceivable lag for fast-output services. | Acceptable for interactive debugging; revisit if user feedback demands sub-100 ms latency (would switch to inotify or push-based capture). |
| Raising `Ecto.NoResultsError` from LiveView mount diverges from sibling LiveViews' "flash + redirect" 404 style. | Explicit decision justified by the Gherkin 404 requirement; documented under Key Technical Decisions. Not a mechanical convention-break — it is a targeted deviation. |
| `File.read!` on mount could stall for multi-MB logs. | In practice, `truncate-on-start` bounds file size per run. If a run produces very large logs in one session, investigate `File.stream!` + chunked initial send as follow-up. |
| tmux client teardown leaks (per `docs/solutions/2026-04-21-erlexec-vs-expty-evaluation.md`). | `LogTailer` does not attach a tmux client; it only reads the on-disk file. Risk does not apply. |
| Route param conflict — `live "/services/:id"` could clash with future `/services` index. | No existing `/services` route exists; if added later, route ordering must put the more specific path first. Noted for future work, not a current concern. |

## Documentation / Operational Notes

- `.gitignore`: verify `tmp/` is ignored; if not, add `tmp/services/` (or just `tmp/`) during Unit 1.
- No runbook or monitoring changes needed — the new LogTailer is low-footprint and failure-degraded, not mission-critical.
- Sessions created before this change that have a running service will not have a log file until the next start; this is acceptable and matches the "truncate-on-start" contract.
- When running tests locally, `mix precommit` runs the full suite plus format; the new feature files add new `@tag`s that can be exercised via `mix test --only feature:service_detail_page`.

## Sources & References

- Related code:
  - `lib/destila/services/service_manager.ex`
  - `lib/destila/terminal/tmux.ex`
  - `lib/destila/workflows.ex`
  - `lib/destila/pub_sub_helper.ex`
  - `lib/destila_web/live/workflow_runner_live.ex`
  - `lib/destila_web/router.ex`
  - `lib/destila_web/components/layouts.ex`
  - `lib/destila/application.ex`
- Related tests:
  - `test/destila_web/live/service_status_sidebar_live_test.exs`
  - `test/support/conn_case.ex`
- Related features:
  - `features/service_status_sidebar.feature`
  - `features/service_setup_command.feature`
- Institutional learning:
  - `docs/solutions/2026-04-21-erlexec-vs-expty-evaluation.md`
- Project guidelines: `AGENTS.md` (aliased as `CLAUDE.md`).
