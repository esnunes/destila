---
title: "feat: Services Index Page"
type: feat
status: completed
date: 2026-04-24
---

# feat: Services Index Page

## Overview

Add a new top-level `/services` page that lists every development service across
all non-archived workflow sessions whose project is configured as a webservice.
Each row shows status, port, session/project, and a clickable `localhost:<port>`
URL when running — clicking the row navigates to the existing
`/services/:id` detail page. The list updates live via PubSub.

## Problem Frame

Destila users juggle multiple long-running web services attached to workflow
sessions. Today each service's status, port, and URL live only on the
per-session detail page at `/services/:id`, which is reachable only from the
session sidebar. There is no single place to answer "what's running and on
which port?" across the whole app. This plan adds a top-level index page that
surfaces that answer and lets a user jump straight to the detail page without
navigating through the parent session.

Lifecycle actions (Start / Stop / Restart / Clear logs) stay exclusive to the
detail page — the index is a read-only surface plus a link-out.

## Requirements Trace

- R1. A new `live "/services", ServicesLive` route exists in the same browser
  scope as the existing `live "/services/:id", ServiceDetailLive`.
- R2. Eligible rows are those from `Destila.Workflows.list_workflow_sessions/0`
  (already filters `archived_at IS NULL` and preloads `:project`) whose project
  passes `Destila.Projects.Project.webservice?/1`; sessions with `project == nil`
  are excluded.
- R3. Each row shows status indicator + port, session title, project name, and
  — only when status is `"running"` and `port` is present — a clickable
  `http://localhost:<port>` URL opened via `target="_blank"` + `rel="noopener"`.
- R4. The whole row (outside the URL pill) navigates via
  `<.link navigate=...>` to `/services/:id`.
- R5. No Start / Stop / Restart / Clear logs controls are exposed on the index.
- R6. An empty state is shown when no eligible services exist.
- R7. A sidebar link to `/services` is added in
  `lib/destila_web/components/layouts.ex`, alongside Crafting Board, Drafts, and
  Projects.
- R8. The list updates live:
  - `{:service_status, state}` on `PubSubHelper.service_topic(session_id)` updates
    that row.
  - `:workflow_session_created` / `:workflow_session_updated` on `"store:updates"`
    recompute eligibility and add/remove rows.
  - Per-session `service:<id>` subscriptions are added/removed in lockstep with
    eligibility.
- R9. A `features/services_index.feature` file defines the Gherkin scenarios,
  and a `test/destila_web/live/services_live_test.exs` covers every scenario via
  `@tag feature: "services_index", scenario: "..."` with the feature docstring
  linking back to the feature file.
- R10. No schema changes, no migrations, no new dependencies.

## Scope Boundaries

- No new lifecycle controls on the index page — Start / Stop / Restart / Clear
  logs stay on `/services/:id`.
- No changes to `ServiceDetailLive` beyond what is required to share rendering
  helpers (see Key Technical Decisions for the explicit "no duplication of
  `Project.webservice?/1`" rule).
- No changes to existing PubSub topic semantics (`"store:updates"` or
  `service:<id>`).
- No changes to the session sidebar's service item in
  `lib/destila_web/live/workflow_runner_live.ex`.
- No filtering, sorting, or pagination controls in this plan — the default is
  the natural order of `list_workflow_sessions/0` (`position` ASC).
- No log preview or tail on the index — that remains exclusive to the detail
  page.

## Context & Research

### Relevant Code and Patterns

- `lib/destila_web/live/service_detail_live.ex` — source of the status pill
  and URL link styling to mirror. In particular, the `status_pill/1`,
  `status_dot/1`, and `url_link/1` function components (lines 310–379) define
  the visual language already shipping for services; the index should reuse that
  vocabulary.
- `lib/destila_web/live/projects_live.ex` (lines 13, 50–52) and
  `lib/destila_web/live/drafts_board_live.ex` — existing LiveView stream
  patterns (`stream/3`, `stream_insert/3`, `phx-update="stream"`).
- `lib/destila_web/live/crafting_board_live.ex` (lines 55–67) and
  `lib/destila_web/live/archived_sessions_live.ex` (lines 6–27) — existing
  "subscribe to `store:updates`, then on any `:workflow_session_created` or
  `:workflow_session_updated` event re-query and re-assign the list" pattern.
- `lib/destila_web/components/layouts.ex` (lines 44–76 and 117–137) — sidebar
  navigation and `sidebar_item/1` component.
- `lib/destila/pub_sub_helper.ex` — `service_topic/1` and the `:service_status`
  broadcast shape. Sessions broadcast `:workflow_session_created` /
  `:workflow_session_updated` via `PubSubHelper.broadcast/2`. Projects broadcast
  `:project_created` / `:project_updated` / `:project_deleted` via the same
  helper — relevant because a project going from webservice → non-webservice
  (or vice versa) should also refresh eligibility.
- `lib/destila/projects/project.ex` — `webservice?/1` (lines 45–47) is the
  single source of truth for "is this project a webservice?"; do **not**
  duplicate the predicate.
- `lib/destila/workflows.ex` (lines 139–145) — `list_workflow_sessions/0`
  already applies the `archived_at IS NULL` filter and preloads `:project`.
- `lib/destila_web/live/workflow_runner_live.ex` — the existing sidebar "globe
  button" pattern:
  `href={"http://localhost:#{@port}"} target="_blank" rel="noopener noreferrer"`.
  The index URL pill should match.
- `test/destila_web/live/service_detail_live_test.exs` — fixture helpers
  (`create_project/1`, `create_session/1`, `webservice_project/1`), the
  `@feature` / `@tag feature: @feature, scenario: "..."` convention, the
  `ClaudeCode.Test.set_mode_to_shared/0` setup, and the existing PubSub-driven
  refresh assertion (lines 290–325). These are the patterns the new test file
  should mirror rather than reinvent.

### Institutional Learnings

No `docs/solutions/` entries relate directly to this feature. The closest prior
art is the `2026-04-24-001-feat-service-detail-page-plan.md` plan and its
shipping implementation, which established the route, PubSub shape, and visual
vocabulary. This plan reuses those conventions deliberately.

### External References

None needed — the work is entirely within existing Phoenix LiveView, PubSub,
and Ecto patterns already used throughout the codebase.

## Key Technical Decisions

- **Filter in the LiveView, not the context.** `Workflows.list_workflow_sessions/0`
  is already used by other views and must stay general; the webservice filter
  is view-specific. Do the filter inline via `Enum.filter/2` using
  `Project.webservice?/1`. Rationale: avoids adding a narrowly-used context
  function and keeps `list_workflow_sessions/0` stable.
- **Reuse `Project.webservice?/1` — do not duplicate its predicate.** All
  eligibility decisions (initial mount, live updates, per-session subscription
  churn) must call this function. Rationale: keeps the business rule single-
  sourced, matches how `ServiceDetailLive` gates access.
- **LiveView stream keyed by session id.** `stream(:services, eligible_sessions)`
  with `phx-update="stream"` and row DOM ids `service-row-<session_id>`.
  Rationale: matches the `projects_live` / `drafts_board_live` pattern, avoids
  memory ballooning, and makes `stream_insert/3` / `stream_delete/3` the
  natural primitives for live updates.
- **Track eligible session ids in a separate assign (MapSet).** The stream
  itself is not enumerable, so we cannot diff it when membership changes. Hold
  `assigns[:subscribed_ids]` (MapSet of session UUIDs) alongside the stream to
  drive subscribe/unsubscribe decisions. Rationale: lets us compute
  `added = new -- old` and `removed = old -- new` without relying on stream
  internals, which is the recommended Phoenix LiveView pattern.
- **Two subscription sources, handled by one rebuild function.**
  - `"store:updates"` covers session and project lifecycle. On any
    `:workflow_session_created`, `:workflow_session_updated`, `:project_updated`,
    or `:project_deleted` event, call a single `refresh_services/1` helper that
    re-queries, diffs `subscribed_ids`, reconciles PubSub subscriptions, and
    applies `stream_insert/3` / `stream_delete/3`.
  - `service:<session_id>` carries `{:service_status, state}` for live
    per-row updates. The `handle_info({:service_status, state}, socket)` clause
    re-fetches the session (cheap, indexed lookup) and calls
    `stream_insert/3` with the refreshed row. Rationale: one reconciliation
    path for membership, one update path for per-row status — each path is
    small and testable in isolation.
- **Subscribe on mount only when `connected?(socket)`.** Matches
  `ServiceDetailLive` and every other LiveView in the app; avoids duplicate
  subscriptions across the two-phase LiveView mount.
- **Empty state uses Tailwind `only:block` sibling inside the stream container.**
  Matches the documented LiveView empty-state pattern for streams (see CLAUDE.md
  LiveView streams section) — a single empty-state element with
  `class="hidden only:block"` rendered as a sibling of the `:for` comprehension.
- **`{:service_status, state}` with a port but `status != "running"` must still
  not render a URL.** The render helper must guard on `status == "running" AND
  is_integer(port)` (mirroring `ServiceDetailLive.url_link/1` at
  `service_detail_live.ex:355–379`), not on port alone. Rationale: "stopping"
  and transient states still carry the last known port in `service_state`.
- **Nil `service_state` is treated as `%{"status" => "stopped"}`** for display,
  matching `ServiceDetailLive` mount at `service_detail_live.ex:37`.
- **Project lifecycle events trigger eligibility recompute.** A project going
  from non-webservice → webservice (because a user added `run_command` and
  `service_env_var`) must make its sessions appear on the index live, without a
  page reload. Projects broadcast `:project_updated` via the shared
  `PubSubHelper.broadcast/2` helper on `"store:updates"`, so `ServicesLive` must
  also match `:project_updated` and `:project_deleted` in its `handle_info`
  clause. Rationale: without this, a fresh webservice project is invisible
  until the user manually refreshes — a real UX regression.

## Open Questions

### Resolved During Planning

- **Can a session row show Start / Stop inline?** No — explicit scope boundary
  (R5). Kept off.
- **Should the plan change `list_workflow_sessions/0`?** No — filter in the
  view. See Key Technical Decisions.
- **What broadcast events on `"store:updates"` do we actually have?** Only
  `:workflow_session_created` and `:workflow_session_updated` for sessions
  (archive and soft-delete both emit `:workflow_session_updated`), plus
  `:project_created`, `:project_updated`, `:project_deleted` for projects. The
  user prompt's mention of "session add/archive events" maps to these — there
  is no `:workflow_session_archived` atom. Confirmed by `grep` across
  `lib/destila/workflows.ex`, `lib/destila/projects.ex`, and
  `lib/destila/pub_sub_helper.ex`.
- **Which project broadcast events are relevant here?** `:project_updated` is
  the most important (webservice ↔ non-webservice transitions); `:project_created`
  is irrelevant on its own (no sessions attached yet); `:project_deleted`
  matters only if the FK semantics leave orphan sessions on the index — in
  practice, session rows would disappear on their own `:workflow_session_updated`
  event, but subscribing to `:project_deleted` gives us a belt-and-suspenders
  refresh that costs nothing.

### Deferred to Implementation

- Icon choice for the sidebar `Services` item — `hero-server-stack` and
  `hero-bolt` are both reasonable candidates. Pick during implementation, just
  make sure the size (`size-5`) and colour treatment match the existing
  `sidebar_item/1` contract.
- Whether to extract `status_pill/1` / `status_dot/1` into a shared component
  module to avoid duplication between `ServiceDetailLive` and `ServicesLive`.
  Defer: start by duplicating inside `ServicesLive` (or re-rendering via an
  internal helper) and extract to `DestilaWeb.ServiceComponents` only if a
  third caller appears. Rationale: avoid premature abstraction — duplicating
  three small function components once is cheaper than designing the right
  shared module shape now.

## Implementation Units

- [x] **Unit 1: Feature file, router, and sidebar link**

**Goal:** Land the non-behavioral scaffolding — the Gherkin spec, the new
route, and the sidebar entry — so later units have a stable target.

**Requirements:** R1, R7, R9

**Dependencies:** None.

**Files:**
- Create: `features/services_index.feature`
- Modify: `lib/destila_web/router.ex`
- Modify: `lib/destila_web/components/layouts.ex`

**Approach:**
- Add `live "/services", ServicesLive` to `lib/destila_web/router.ex` inside
  the existing `scope "/", DestilaWeb do ... pipe_through :browser` block,
  placed immediately *before* `live "/services/:id", ServiceDetailLive` so the
  static route is matched first. (Phoenix routes match in source order; a
  static `/services` must come before `/services/:id`.)
- Add a new `<.sidebar_item navigate={~p"/services"} icon="hero-server-stack"
  label="Services" active={@page_title == "Services"} />` in
  `lib/destila_web/components/layouts.ex` alongside Crafting Board, Drafts,
  and Projects (inside the top nav block, before the divider at line 64).
- Create `features/services_index.feature` with the full Gherkin scenarios
  enumerated in this plan's "Test scenarios" for Unit 2 and Unit 3 below,
  following the format of `features/service_detail_page.feature`.

**Patterns to follow:**
- `features/service_detail_page.feature` for Gherkin format (feature-level
  context paragraph + one `Scenario:` block per behavior).
- `lib/destila_web/components/layouts.ex` lines 45–62 for sidebar item
  placement and attribute shape.

**Test scenarios:**
- Test expectation: none — the route and sidebar are verified indirectly by
  the Unit 3 tests (sidebar reachability scenario + the mount tests that hit
  `~p"/services"`). The feature file itself is not code, so it has nothing to
  assert against on its own.

**Verification:**
- `mix phx.routes | grep services` shows the new `/services` route resolves
  to `DestilaWeb.ServicesLive`.
- Visiting the app in dev shows the new Services link in the sidebar
  (note: the LiveView module does not exist yet, so clicking it will 500 —
  resolved in Unit 2).
- `features/services_index.feature` exists with all scenarios and parses as
  valid Gherkin (no linter in the repo, so visual review is sufficient).

---

- [x] **Unit 2: `ServicesLive` module — mount and render**

**Goal:** Ship the LiveView module that fetches eligible sessions, renders
them as a stream of compact table rows with the correct status / port / URL /
empty-state semantics, and navigates rows to `/services/:id`. No live updates
yet — that is Unit 3.

**Requirements:** R2, R3, R4, R5, R6

**Dependencies:** Unit 1 (route must exist for the LiveView to be reachable).

**Files:**
- Create: `lib/destila_web/live/services_live.ex`

**Approach:**
- `mount/3`: compute eligible sessions from
  `Destila.Workflows.list_workflow_sessions/0` filtered through
  `Project.webservice?/1` (after guarding against `session.project == nil`).
  Assign `:page_title` to `"Services"` (drives sidebar active state), then
  `stream/3` the eligible sessions as `:services`. Do **not** subscribe to
  anything in this unit — that lands in Unit 3.
- `render/1`: wrap with `<Layouts.app flash={@flash} page_title={@page_title}>`,
  show a page header (title + subtle subtitle), then a single container
  `<div id="services-list" phx-update="stream" class="...">` holding:
  1. An empty-state element with `class="hidden only:block ..."` and a stable
     DOM id `id="services-empty"` (text: "No services yet" or similar).
  2. A `:for={{dom_id, ws} <- @streams.services}` row with
     `id={dom_id}` and a stable human id attribute for tests
     (`data-session-id={ws.id}`). The row is wrapped in
     `<.link navigate={~p"/services/#{ws.id}"} id={"service-row-#{ws.id}"}>`
     so clicking anywhere navigates to the detail page.
- Inside each row, render (in table-style columns):
  - A `status_dot/1` + capitalized status label (reuse the
    `ServiceDetailLive` styling vocabulary — either by duplicating the small
    helper or by rendering inline with the same Tailwind classes).
  - The port (`:port` from `ws.service_state`), monospaced, prefixed with a
    dimmed colon, shown only when present.
  - The session title (`ws.title`).
  - The project name (`ws.project.name`), styled secondary.
  - A URL pill — rendered **only** when
    `ws.service_state["status"] == "running"` and
    `is_integer(ws.service_state["port"])`. The pill is an `<a>` with
    `href="http://localhost:#{port}"`, `target="_blank"`,
    `rel="noopener noreferrer"`, and a stable DOM id
    `id={"service-url-#{ws.id}"}`. Because the row is wrapped in `<.link>`,
    the URL pill must be a nested `<a>` — HTML forbids nesting `<a>` inside
    `<a>`, so in practice the URL pill must live **outside** the row-level
    `<.link>`. Resolution: make the row a flex container whose main area is
    the `<.link navigate>` wrapper and whose trailing cell (the URL pill) is a
    sibling `<a href target="_blank">` outside the navigate link. This mirrors
    the `ServiceDetailLive` header layout where the status pill, URL pill,
    and controls sit side-by-side.
- Treat nil `ws.service_state` as `%{"status" => "stopped"}` for display (no
  URL, no port), matching `ServiceDetailLive` mount behavior.
- No `handle_event/3` clauses in this unit — the index is read-only.

**Patterns to follow:**
- `lib/destila_web/live/service_detail_live.ex:310–379` for `status_dot/1`,
  `status_pill/1`, and the URL-link render guard (`status == "running" AND
  is_integer(port)`).
- `lib/destila_web/live/projects_live.ex` for the `stream/3` + stream
  template shape.
- CLAUDE.md "LiveView streams" section for the `hidden only:block` empty-state
  pattern.
- `lib/destila_web/live/archived_sessions_live.ex` for the overall page
  structure (header + list container) at a similar information density.

**Test scenarios:** *(covered in Unit 3's test file; verification here is
visual and via `mix compile --warnings-as-errors`)*

**Verification:**
- `mix compile --warnings-as-errors` passes.
- Visiting `/services` in dev with:
  - Zero eligible sessions → empty state is visible.
  - A running service → row shows status dot green, port, title, project,
    and a clickable `localhost:<port>` pill that opens in a new tab.
  - A stopped service → row shows status dot neutral, no URL pill.
  - An archived session → does not appear.
  - A session whose project is nil or not a webservice → does not appear.
  - Clicking the row (outside the URL pill) navigates to `/services/<id>`.

---

- [x] **Unit 3: Live updates via PubSub + tests**

**Goal:** Make the index update in real time as services start / stop and as
sessions and projects are created, updated, archived, or deleted — and cover
every Gherkin scenario with a LiveView test.

**Requirements:** R8, R9

**Dependencies:** Unit 2 (the LiveView must render rows before we can update
them).

**Files:**
- Modify: `lib/destila_web/live/services_live.ex`
- Create: `test/destila_web/live/services_live_test.exs`

**Approach:**
- **On mount (`connected?(socket)` branch):**
  - Subscribe to `"store:updates"` once.
  - Compute the eligible session ids, subscribe to each
    `PubSubHelper.service_topic(id)`, and store the set in
    `assigns[:subscribed_ids]` (a `MapSet`).
- **Add a `refresh_services/1` private helper** that:
  1. Re-queries eligible sessions via the same filter used at mount.
  2. Computes `new_ids = MapSet.new(Enum.map(eligible, & &1.id))`.
  3. Computes `added = MapSet.difference(new_ids, old_ids)` and
     `removed = MapSet.difference(old_ids, new_ids)`.
  4. For each `id in added`: `Phoenix.PubSub.subscribe(Destila.PubSub,
     PubSubHelper.service_topic(id))`. For each `id in removed`:
     `Phoenix.PubSub.unsubscribe(Destila.PubSub,
     PubSubHelper.service_topic(id))`.
  5. Applies `stream_delete/3` for each removed session (look it up from the
     old eligible list cached in a second assign, or reconstruct a minimal
     shim `%{id: id}` — `stream_delete/3` only needs the dom key).
  6. For each session still present or newly added, call `stream_insert/3` so
     the row reflects the latest `service_state` (preload already took care of
     `project`).
  7. Reassigns `:subscribed_ids` to `new_ids`.
- **Add `handle_info/2` clauses:**
  - `{event, _}` when `event in [:workflow_session_created,
    :workflow_session_updated, :project_updated, :project_deleted]` →
    `refresh_services/1`.
  - `{:service_status, state}` → derive the session id from `state` (it is
    keyed by `"workflow_session_id"` — confirm from the broadcast shape; if
    not present, fetch the subscribed session ids and find the one whose
    current state matches, or adjust the helper in
    `Destila.PubSubHelper.broadcast_service_status/2` only if strictly needed.
    Prefer to derive the id from the topic by inspecting the broadcast
    contract during implementation). For the row update, re-fetch the session
    via `Workflows.get_workflow_session/1`, rebuild the row, and
    `stream_insert/3`. If the session has become ineligible (e.g. archived
    simultaneously), fall back to `stream_delete/3` and unsubscribe.
  - `handle_info(_, socket), do: {:noreply, socket}` catch-all, matching
    every other LiveView in this app.
- **Tests** (`test/destila_web/live/services_live_test.exs`):
  - `@moduledoc` references the feature file at
    `features/services_index.feature`.
  - `@feature "services_index"`.
  - Reuse `create_project/1`, `create_session/1`, `webservice_project/1` from
    `test/destila_web/live/service_detail_live_test.exs`. Either inline-copy
    them (matching the existing test's in-file pattern) or extract to a
    shared helper — defer that choice to implementation; copying is fine.
  - Drive live-update scenarios by calling
    `PubSubHelper.broadcast_service_status(ws.id, state)` and
    `Phoenix.PubSub.broadcast(Destila.PubSub, "store:updates",
    {:workflow_session_updated, updated_ws})`. **Never use `Process.sleep/1`**.
    When synchronization is needed, use `_ = :sys.get_state(view.pid)` or
    `Process.monitor/1` per the project's test guidelines.
  - Use `ClaudeCode.Test.set_mode_to_shared()` in the test setup (matches
    `service_detail_live_test.exs` line 16) to avoid AI stub leakage even
    though this view never calls Claude.

**Patterns to follow:**
- `lib/destila_web/live/crafting_board_live.ex:55–67` — the "match multiple
  store:updates events, re-query, re-assign" pattern.
- `lib/destila_web/live/archived_sessions_live.ex:6–27` — mount pattern with
  a single subscription and a single handle_info clause for session events.
- `lib/destila_web/live/service_detail_live.ex:123–160` — `{:service_status,
  state}` and `{:workflow_session_updated, ws}` handling shapes.
- `test/destila_web/live/service_detail_live_test.exs:290–325` — how to drive
  PubSub-based live-update assertions in LiveView tests.

**Test scenarios:** *(one `@tag feature: @feature, scenario: "..."` per
scenario below; every scenario in `features/services_index.feature` must have
at least one linked test)*

- Happy path: **Index lists services for non-archived sessions with webservice
  projects** — seed two eligible sessions (one running, one stopped) + one
  ineligible control, visit `~p"/services"`, assert both eligible rows appear
  by `#service-row-<id>` and the ineligible one does not.
- Edge case: **Archived sessions are excluded** — seed an eligible session,
  archive it via `Workflows.archive_workflow_session/1`, visit the page, assert
  the row is not rendered.
- Edge case: **Sessions whose project is not a webservice are excluded** —
  seed a session with a project that has `run_command` nil or
  `service_env_var` nil, assert the row is not rendered.
- Edge case: **Sessions with no project are excluded** — seed a session with
  `project_id: nil`, assert the row is not rendered.
- Happy path: **Row shows status, port, session, and project** — seed a
  running service with port 4321, assert the row renders the status dot,
  port text, session title, and project name via `#service-row-<id>`
  selectors plus text matching.
- Happy path: **Running service row shows a clickable localhost URL** — seed
  a running service, assert `#service-url-<id>[href="http://localhost:4321"]
  [target="_blank"][rel="noopener noreferrer"]` is present.
- Edge case: **Stopped service row hides the URL** — seed a stopped service,
  assert `#service-url-<id>` is not present.
- Integration: **Row navigates to the service detail page** — assert the row
  contains an `<a>` navigating to `/services/#{ws.id}` (check the `href`
  attribute rendered by `<.link navigate>`).
- Edge case: **No inline lifecycle controls in the list** — assert none of
  `#start-service-button`, `#stop-service-button`, `#restart-service-button`,
  `#clear-logs-button` exist on the `/services` page.
- Edge case: **Empty state when no eligible services exist** — seed only
  ineligible sessions, visit the page, assert `#services-empty` is present.
- Integration: **List updates live when a service starts** — mount with a
  stopped service, broadcast
  `PubSubHelper.broadcast_service_status(ws.id, %{"status" => "running",
  "port" => 4321})`, assert `#service-url-<id>` becomes present.
- Integration: **List updates live when a service stops** — mount with a
  running service, broadcast `{"status" => "stopped"}` on the service topic,
  assert `#service-url-<id>` is no longer present.
- Integration: **Services page is reachable from the top-level navigation** —
  visit the dashboard or any page, assert the sidebar has a link to
  `~p"/services"` (selector: `nav a[href="/services"]` or a stable sidebar
  item id if one is added in Unit 1).

**Verification:**
- `mix test --only feature:services_index` passes with every scenario in
  `features/services_index.feature` linked to at least one test.
- `mix precommit` passes cleanly.
- Manual smoke test in dev: open `/services` with one running service and
  one stopped service, start the stopped one via `/services/<id>`, observe
  the row on `/services` flip to "running" with a URL pill within ~1 second.

## System-Wide Impact

- **Interaction graph:** The new LiveView subscribes to two PubSub surfaces —
  `"store:updates"` and per-session `service:<id>` topics. Both are already
  long-standing topics; no producer needs to change. Adding this subscriber
  does not alter any existing consumer.
- **Error propagation:** The new LiveView has no side effects — a crash in
  `handle_info` bubbles up as a LiveView crash and is recovered by the
  socket's supervision tree, identical to every other LiveView in the app.
  No new error paths are introduced upstream.
- **State lifecycle risks:** The only meaningful state is the
  `subscribed_ids` MapSet. The risk is a subscription leak or a duplicate
  subscription. Mitigations:
  (a) subscribe only inside `connected?(socket)`,
  (b) always reconcile via `MapSet.difference/2` before subscribing,
  (c) unsubscribe symmetrically on removal. No process-level cleanup is
  required — LiveView terminates the subscriber when the socket closes.
- **API surface parity:** None — this is an internal UI addition. No public
  API, CLI flag, or exported type changes.
- **Integration coverage:** Scenarios that unit tests alone cannot prove are
  the three live-update scenarios (start, stop, add/remove). The test file
  covers them by broadcasting real PubSub messages to the real topic and
  asserting on the rendered view — that is the only trustworthy integration
  surface for this feature.
- **Unchanged invariants:**
  - `ServiceDetailLive` behavior is unchanged.
  - The session sidebar's service item in
    `lib/destila_web/live/workflow_runner_live.ex` is untouched.
  - `Destila.Workflows.list_workflow_sessions/0` signature and behavior are
    unchanged.
  - Every existing PubSub topic and message shape is unchanged. The
    `service_topic/1` and `service_status` contract stays exactly as
    `ServiceDetailLive` uses it today.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Router ordering bug — placing `live "/services", ServicesLive` **after** `live "/services/:id", ServiceDetailLive` would make `/services` match `/services/:id` with `id = ""` and 404 unexpectedly. | Place the static route strictly before the parametrized route in `router.ex`. Confirm via `mix phx.routes \| grep services` showing both routes with `/services` first. |
| Nested `<a>` inside `<a>` — the row is a navigate link and the URL pill is a target-blank anchor; nesting them is invalid HTML and LiveView will silently strip the inner one in some browsers. | Render the URL pill as a sibling of the `<.link navigate>` wrapper inside a flex row container, not inside it. See Unit 2 Approach. |
| Subscription leak on rapid eligibility churn — if a session toggles eligibility multiple times before the LiveView processes messages, the MapSet must reconcile against the **current** query result each time, never a cached snapshot. | `refresh_services/1` always re-queries the database and diffs against `assigns[:subscribed_ids]` — no caching layer in between. |
| `{:service_status, state}` arrives for a session that has since become ineligible (e.g. archived a moment earlier) — a naive `stream_insert/3` would reintroduce a ghost row. | The handler checks current eligibility before inserting; if ineligible, it falls back to `stream_delete/3` + unsubscribe. |
| `Project.webservice?/1` predicate drift — if someone adds a third field to the predicate, this view must pick it up for free. | The view calls `Project.webservice?/1` directly (never inlines the logic); predicate drift is free by construction. |
| Test flakiness from PubSub ordering — sending a broadcast and immediately asserting on `render(view)` can race the LiveView's message queue. | Use `_ = :sys.get_state(view.pid)` after broadcasts to force message processing before asserting (per CLAUDE.md test guidelines). |

## Documentation / Operational Notes

- No user-facing documentation exists for the per-session `/services/:id` page
  today; adding one for the new index is out of scope.
- No rollout flag is needed — the route is additive and strictly read-only.
- No monitoring changes. If we wanted to, we could add a Telemetry event on
  mount to count `/services` visits, but that is deferred indefinitely.

## Sources & References

- Related code:
  - `lib/destila_web/live/service_detail_live.ex`
  - `lib/destila/workflows.ex`
  - `lib/destila/projects/project.ex`
  - `lib/destila/pub_sub_helper.ex`
  - `lib/destila_web/router.ex`
  - `lib/destila_web/components/layouts.ex`
  - `lib/destila_web/live/crafting_board_live.ex`
  - `lib/destila_web/live/archived_sessions_live.ex`
  - `lib/destila_web/live/projects_live.ex`
  - `test/destila_web/live/service_detail_live_test.exs`
  - `features/service_detail_page.feature`
- Related plans:
  - `docs/plans/2026-04-24-001-feat-service-detail-page-plan.md`
  - `docs/plans/2026-04-14-003-feat-service-status-sidebar-plan.md`
  - `docs/plans/2026-04-14-001-feat-project-service-management-plan.md`
- External docs: none required.
