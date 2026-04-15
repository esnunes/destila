---
title: "feat: Add service status item to workflow session sidebar"
type: feat
status: completed
date: 2026-04-14
---

# feat: Add service status item to workflow session sidebar

## Overview

Add a "Service" item to the right sidebar's "Workflow Session" section in `WorkflowRunnerLive`, alongside the existing "User Prompt" and "Terminal" items. The item reflects whether the project's development service is running or stopped, with conditional link behavior that opens the service in a new browser tab when running.

## Problem Frame

After the project service management feature shipped (plan 001), there is no UI indicator for the service's current state. Users have no way to know whether the service is running or to quickly open it in a browser. Adding a sidebar item makes service state visible and actionable.

## Requirements Trace

- R1. Show a "Service" item in the sidebar when the project has a `run_command` configured
- R2. Show a disabled/grayed-out "Service" item when no `run_command` is configured, indicating the feature exists but isn't set up
- R3. Icon color reflects service status: green when running, muted/gray when stopped or nil
- R4. When running and port is available, render as an `<a target="_blank">` link to `http://localhost:<port>` using the first port from `project.port_definitions` resolved against `service_state["ports"]`
- R5. When stopped (or no port available), render as a static non-clickable element
- R6. Real-time updates happen automatically via existing `handle_info({:workflow_session_updated, ws}, ...)`
- R7. Handle edge cases: nil `service_state`, empty `port_definitions`, port not yet assigned

## Scope Boundaries

- No changes to `ServiceManager`, schemas, or PubSub plumbing — all data flows already exist
- No new assigns needed — `@project` and `@workflow_session` are already available in the template
- No new `handle_event` clauses — the link is a plain `<a>` tag, not a LiveView event

## Context & Research

### Relevant Code and Patterns

- **Sidebar location**: `lib/destila_web/live/workflow_runner_live.ex` lines 647-696, inside `#user-prompt-section > div.space-y-0.5`
- **User Prompt item** (lines 652-673): `<button>` with `phx-click`, eye icon trailing — always rendered
- **Terminal item** (lines 674-694): `<.link>` with `navigate`, arrow icon trailing — conditionally rendered via `:if={@worktree_path}`
- **Project schema** (`lib/destila/projects/project.ex`): `run_command` (string, nullable), `port_definitions` (`{:array, :string}`, default `[]`)
- **Session schema** (`lib/destila/workflows/session.ex`): `service_state` (map, nullable) — values: `nil`, `%{"status" => "running", "ports" => %{...}}`, `%{"status" => "stopped", ...}`
- **Mount** (`workflow_runner_live.ex` lines 48-50): `@project` is loaded from `workflow_session.project_id`
- **Real-time flow**: `ServiceManager` → `Workflows.update_workflow_session/2` → PubSub broadcast → `handle_info` re-fetches session → template re-renders

### Institutional Learnings

- All sidebar items follow a consistent visual pattern: full-width row, leading icon in `span.size-5`, label in `span.text-sm`, trailing action icon
- Test files for sidebar items (`user_prompt_sidebar_live_test.exs`, `open_terminal_live_test.exs`) use dedicated test modules per feature with `has_element?` assertions on DOM IDs
- Conditional sidebar items use `:if={}` on the element itself

## Key Technical Decisions

- **Always render the item, conditionally style it**: Show the Service item regardless of `run_command` presence. When no `run_command` exists, render a disabled/muted static element. This teaches users the feature exists.
- **Conditional element type based on status**: When running with a resolvable port, render as `<a href="..." target="_blank">`. When stopped or no port, render as a `<div>`. Use `<%= if ... %>` to switch between the two elements.
- **Port resolution via helper function**: Extract a private `service_url/2` function that takes `project` and `service_state`, finds the first entry from `project.port_definitions` in `service_state["ports"]`, and returns either a URL string (`http://localhost:<port>`) or nil. This keeps the template clean.
- **Icon**: Use `hero-server-micro` — semantically fits "service/server" and is available in the Heroicons micro set.

## Open Questions

### Resolved During Planning

- **Which icon?**: `hero-server-micro` — conveys "service" clearly and matches the micro icon style used by other sidebar items.
- **Where to put the helper?**: Inline in the LiveView module as a private function, following the pattern of existing helpers like `assign_worktree_path/2`.

### Deferred to Implementation

- None — all planning-time questions resolved.

## Implementation Units

- [ ] **Unit 1: Add Gherkin feature file**

**Goal:** Create the feature file documenting service status sidebar scenarios.

**Requirements:** All (R1-R7)

**Dependencies:** None

**Files:**
- Create: `features/service_status_sidebar.feature`

**Approach:**
- Write the 7 Gherkin scenarios from the user prompt verbatim

**Patterns to follow:**
- Existing feature files in `features/` (e.g., `features/exported_metadata.feature`)

**Test expectation:** none — this is a documentation artifact

**Verification:**
- Feature file exists and covers all 7 scenarios

---

- [ ] **Unit 2: Add service status item to sidebar template**

**Goal:** Render the Service item in the sidebar with correct conditional behavior for all states.

**Requirements:** R1, R2, R3, R4, R5, R7

**Dependencies:** None (data already flows)

**Files:**
- Modify: `lib/destila_web/live/workflow_runner_live.ex`

**Approach:**
- Add a private `service_url/2` function that takes `project` and `service_state`, returns `"http://localhost:<port>"` or nil. Resolves port by finding the first entry from `project.port_definitions` in `service_state["ports"]`.
- Insert the Service item after the Terminal link (after line 694), before `</div>` closing the `space-y-0.5` container.
- Use `<%= if @project do %>` to gate rendering entirely (no project = no service item), then nest `<%= if @project.run_command do %>` to split between configured and unconfigured states.
- When configured, derive `service_running?` from `@workflow_session.service_state["status"] == "running"` and `url` from `service_url(@project, @workflow_session.service_state)`.
- When running + URL available: render `<a id="service-status-link" href={url} target="_blank" ...>` with green icon and arrow trailing icon.
- When running + no URL (empty port_definitions): render `<div id="service-status-item" ...>` with green icon but not clickable.
- When stopped/nil: render `<div id="service-status-item" ...>` with muted icon.
- When no `run_command`: render `<div id="service-status-item" ...>` with fully muted styling and a tooltip indicating no run command is configured.
- Icon color: `text-green-500` when running, `text-base-content/30` when stopped/nil, `text-base-content/20` when no run command.
- Follow the exact class pattern from User Prompt and Terminal items.

**Patterns to follow:**
- Terminal link conditional rendering (`:if={@worktree_path}`)
- Sidebar item CSS classes: `w-full flex items-center gap-2.5 px-2 py-1.5 rounded-md ...`
- Leading icon: `span.size-5.rounded.flex.items-center.justify-center.shrink-0` with `<.icon name="hero-server-micro" class="size-3.5 ...">`

**Test scenarios:**
- Happy path: project with `run_command` and running service with ports → renders as clickable link with green icon and correct href
- Happy path: project with `run_command` and stopped service → renders as static div with muted icon
- Edge case: project with `run_command` but `service_state` is nil → renders as static div with muted icon
- Edge case: project with `run_command`, running service, but empty `port_definitions` → renders as static div (not link) with green icon
- Edge case: project with `run_command`, running service, port_definitions has entries but ports map doesn't contain first key → renders as static div with green icon
- Edge case: no project (nil) → service item not rendered at all
- Happy path: project without `run_command` → renders disabled item with muted styling

**Verification:**
- Service item appears in the sidebar in all expected states
- Link href is correct when service is running with ports
- Item is not clickable when stopped
- Disabled state visible when no run command

---

- [ ] **Unit 3: Write LiveView tests**

**Goal:** Test all service status sidebar states.

**Requirements:** R1-R7

**Dependencies:** Unit 2

**Files:**
- Create: `test/destila_web/live/service_status_sidebar_live_test.exs`

**Approach:**
- Follow the pattern from `user_prompt_sidebar_live_test.exs` and `open_terminal_live_test.exs`.
- Create helper functions to build projects with/without `run_command` and `port_definitions`, and sessions with/without `service_state`.
- Set `service_state` directly on the workflow session via `Destila.Workflows.update_workflow_session/2` — no need for ServiceManager.
- Test element presence/absence using `has_element?` with DOM IDs.
- Test link href using selector `#service-status-link[href="..."]`.
- Test icon classes using selectors.
- Test real-time update by broadcasting a PubSub message and asserting the DOM changes.

**Patterns to follow:**
- `test/destila_web/live/user_prompt_sidebar_live_test.exs` — module structure, setup, helpers, assertions
- `test/destila_web/live/open_terminal_live_test.exs` — testing link href with selector

**Test scenarios:**
- Happy path: Service item visible when project has run_command → `has_element?(view, "#service-status-item")` or `has_element?(view, "#service-status-link")`
- Happy path: Service item disabled when project has no run_command → `has_element?(view, "#service-status-item")` with disabled indicator, `refute has_element?(view, "#service-status-link")`
- Happy path: Service icon muted when stopped → icon element has muted class
- Happy path: Service icon green when running → icon element has green class
- Happy path: Running service link href points to correct port → `has_element?(view, ~s|#service-status-link[href="http://localhost:4000"]|)`
- Edge case: Service item not clickable when stopped → `refute has_element?(view, "#service-status-link")`
- Edge case: nil service_state treated as stopped → same assertions as stopped
- Edge case: empty port_definitions, running service → no link element, has green icon
- Integration: Real-time update changes icon color → update session service_state via PubSub broadcast, assert DOM changes

**Verification:**
- All tests pass
- Tests cover all 7 Gherkin scenarios with `@tag feature:` and `@tag scenario:` annotations

## System-Wide Impact

- **Interaction graph:** Only the `WorkflowRunnerLive` template changes. No callbacks, middleware, or entry points affected.
- **Error propagation:** No new error paths — all data access is on already-loaded assigns.
- **State lifecycle risks:** None — `service_state` is read-only in this context, written by `ServiceManager` through an existing flow.
- **API surface parity:** No other interfaces need this change.
- **Integration coverage:** The real-time update test covers the PubSub → LiveView → template re-render flow.
- **Unchanged invariants:** `ServiceManager`, project/session schemas, PubSub broadcasting all remain unchanged.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `@project` could be nil if session has no project | Guard with `@project && @project.run_command` before rendering the configured state |
| `service_state["ports"]` map key ordering | Always use `project.port_definitions` (ordered list) to determine first port |
| `hero-server-micro` icon may not exist in current Heroicon set | Verify during implementation; fall back to `hero-server-stack-micro` if needed |

## Sources & References

- Related plan: `docs/plans/2026-04-14-001-feat-project-service-management-plan.md`
- Sidebar pattern: `docs/plans/2026-04-09-feat-user-prompt-sidebar-plan.md`
- Terminal item pattern: `docs/plans/2026-04-09-feat-open-terminal-button-plan.md`
