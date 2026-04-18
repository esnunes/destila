---
title: "feat: Allow users to delete workflow sessions"
type: feat
status: active
date: 2026-04-17
---

# feat: Allow users to delete workflow sessions

## Overview

Add a soft-delete capability for workflow sessions. A new "Delete" action on the session detail page sets a `deleted_at` timestamp after a native browser confirmation. Deleted sessions are hidden from every UI surface (crafting board, dashboard, archived sessions page, exported-metadata listings, session detail page, AI session detail page) and have no in-app recovery path. Recovery is console-only.

The feature mirrors the existing `archive_workflow_session/1` flow — including service cleanup and live AI/Claude session shutdown — but cannot be undone from the UI. Project deletion continues to be blocked while a project has any linked workflow session, including soft-deleted ones.

## Problem Frame

Archived sessions are still visible (and restorable) on the archived sessions page, so users have no way to permanently remove a session they no longer want to see anywhere. The archive flow is for "quiet but keep around"; users now also need "make this go away" semantics with a safety net at the database level (rather than a hard delete that loses all child records).

## Requirements Trace

- R1. Add a nullable `deleted_at` UTC datetime column to `workflow_sessions` and include it in the schema's changeset.
- R2. Add a "Delete" button on the session detail page (`/sessions/:id`) alongside Archive/Unarchive. Available regardless of session state (active, processing, archived, done).
- R3. Clicking Delete prompts a native browser confirmation (`data-confirm`). On confirm, the session is soft-deleted and the user is redirected to the page they came from, falling back to `/crafting`.
- R4. Deleted sessions are invisible on: crafting board, dashboard, archived sessions page, exported-metadata listings (used for source-session selectors), session detail page, AI session detail page. Direct navigation to a deleted session's detail URL surfaces as not-found via the existing redirect-with-flash behavior.
- R5. Deleting a running session first stops its service and any live AI/Claude sessions for the workflow — same cleanup performed by archive.
- R6. There is no in-UI restore path. The `unarchive`-style equivalent does not exist for delete.
- R7. Project deletion continues to be blocked when any workflow session is linked to it, including soft-deleted ones (`count_by_project/1` and `count_by_projects/0` keep counting deleted rows).
- R8. A `:workflow_session_updated` event is broadcast on delete. Subscribers already refetch their lists, and deleted rows naturally drop out via the new filter.

## Scope Boundaries

- No hard-delete of child records (`messages`, `ai_sessions`, `phase_executions`, `session_metadata`). The workflow session row stays in the database with `deleted_at` set.
- No trash/restore UI, no admin recovery panel, no listing of deleted sessions anywhere in the app.
- No custom confirmation modal or custom JS hook for the confirmation — Phoenix's built-in `data-confirm` only.
- No new PubSub event type. Reuse `:workflow_session_updated`.
- No backfill in the migration — the column is nullable and starts null for all existing rows.
- No changes to `count_by_project/1` or `count_by_projects/0` — they continue to count all linked sessions.
- No change to the existing `archive_workflow_session/1` / `unarchive_workflow_session/1` behavior.

## Context & Research

### Relevant Code and Patterns

- `lib/destila/workflows.ex:206-217` — `archive_workflow_session/1`: the reference implementation for service + AI cleanup, schema update, and broadcast.
- `lib/destila/workflows.ex:64-80` — `list_workflow_sessions/0` (active list, filters `is_nil(archived_at)`) and `list_archived_workflow_sessions/0` (archived list). Both need to also exclude `deleted_at`.
- `lib/destila/workflows.ex:82-88` — `get_workflow_session/1` and `get_workflow_session!/1`. The non-bang fetcher must return `nil` for deleted rows so existing 404 redirects in `WorkflowRunnerLive` and `AiSessionDetailLive` apply automatically.
- `lib/destila/workflows.ex:170-182` — `list_sessions_with_exported_metadata/1`: feeds source-session selectors and must also exclude deleted rows.
- `lib/destila/workflows.ex:188-204` — `count_by_project/1` and `count_by_projects/0`: must keep counting all rows including deleted ones (do not compose on the new base query).
- `lib/destila/workflows/session.ex:39-56` — schema and changeset. New `deleted_at` field follows the same shape as `archived_at` (`field :archived_at, :utc_datetime`).
- `lib/destila_web/live/workflow_runner_live.ex` — session detail LiveView. Mount handles missing session (lines 28-85) by flashing "Session not found" and pushing to `/crafting`. Archive/Unarchive event handlers (lines 107-123) are the pattern to mirror.
- `lib/destila_web/live/ai_session_detail_live.ex:19-54` — AI session detail mount. Calls `Workflows.get_workflow_session/1`; returns nil → flash + redirect. Once the base query excludes deleted rows, no template change is needed here.
- `lib/destila_web/live/crafting_board_live.ex` — crafting board LiveView. Uses `list_workflow_sessions/0` and re-fetches on `:workflow_session_updated`.
- `lib/destila_web/live/dashboard_live.ex` — dashboard LiveView. Same pattern as crafting board.
- `lib/destila_web/live/archived_sessions_live.ex` — archived sessions page. Uses `list_archived_workflow_sessions/0`.
- `lib/destila/projects.ex:39-52` — `delete_project/1`: project deletion guard. Calls `Destila.Workflows.count_by_project/1`. Must keep counting deleted rows.
- `lib/destila/services/service_manager.ex:43-47` — `cleanup/1`: kills the tmux window and clears `service_state`.
- `lib/destila/ai/claude_session.ex` — `stop_for_workflow_session/1`: stops live AI/Claude sessions for a workflow.
- `lib/destila/pub_sub_helper.ex` — `broadcast/2` pipes `{:ok, entity}` results onto the `"store:updates"` topic; subscribers receive `{:workflow_session_updated, ws}` tuples.
- `lib/destila_web/router.ex:21-35` — router. The `:browser` pipeline is small and well-scoped; adding a single `put_referer` plug for the session-detail route is straightforward.
- `lib/destila_web/endpoint.ex:15` — `connect_info: [session: @session_options]`. Only `session` is in connect_info, so the cleanest way to surface a referer to LiveView mount is via a router plug that places it in the session (no JS or app.js changes needed).

### Institutional Learnings

- From the project archiving plan (`docs/plans/2026-04-15-002-feat-project-archiving-plan.md`): when adding a soft-delete-style timestamp, every listing query must be audited. A previous omission missed `list_sessions_with_exported_metadata`-style helpers; the same audit applies here.
- The existing archive reuses `:workflow_session_updated`, which is the right event-shape choice — subscribers refetch their lists, and rows that no longer match the filter naturally disappear. Adding a new `:workflow_session_deleted` event would force every subscriber to add a handler and would not improve behavior.
- The `Session` changeset is permissive (`cast` includes most fields). Adding `deleted_at` to the cast list is consistent with how `archived_at` is exposed to internal callers via `Session.changeset/2`.

### External References

None — the work is fully grounded in existing repo patterns.

## Key Technical Decisions

- **Reuse `archived_at` shape for `deleted_at`** — same nullable `:utc_datetime`, same changeset cast inclusion, same indexing strategy. Consistency makes the behavior predictable and reduces migration/test surface.
- **Single shared private base query** — introduce one `base_session_query/0` (or equivalent name) inside `Destila.Workflows` that returns `from ws in Session, where: is_nil(ws.deleted_at)`. Compose all read paths on it: active list, archived list, single fetch, exported-metadata listing. This makes "deleted rows are invisible" structurally enforced rather than checklist-enforced. The fact that the original archive timestamp had to be added to multiple queries one-by-one is the prior-art that motivates this consolidation.
- **`get_workflow_session/1` returns nil for deleted rows** — existing not-found redirects in `WorkflowRunnerLive` and `AiSessionDetailLive` then apply automatically. No new redirect logic required at any LiveView.
- **`get_workflow_session!/1` also excludes deleted rows** — internal callers should treat deleted rows as gone. The few internal call sites for the bang version (PubSub handler in `WorkflowRunnerLive`, `update_workflow_session/2` overload) either are protected by the not-found redirect upstream or operate on freshly created/loaded sessions where deleted_at would not be set.
- **Count helpers stay outside the base query** — `count_by_project/1` and `count_by_projects/0` keep using a raw `from(ws in Session, ...)`. Project deletion is blocked when any session — deleted or not — is linked to the project.
- **Reuse `:workflow_session_updated` PubSub event** — no new event type. Subscribers already refetch and the new filter excludes the row.
- **Native `data-confirm`, no custom JS** — exactly mirrors the existing Archive button in `WorkflowRunnerLive` (line 727: `data-confirm="Archive this session? It will be hidden from the crafting board."`). Same pattern for Delete with a stronger message.
- **Capture referer via a router-scoped plug** — add a small `put_referer` plug applied to the `/sessions/:id` route (or via a small additional pipeline) that reads `Plug.Conn.get_req_header(conn, "referer")` and stores it in session under a scoped key (e.g., `"session_detail_referer"`). The LiveView's `mount/3` reads from session and falls back to `~p"/crafting"`. This avoids any `app.js` changes, any custom hooks, and keeps the referer mechanism self-contained. The plug clears the key after reading so it does not leak across navigations.
- **Referer sanity check** — if the captured referer points back to the session being deleted (same `/sessions/:id` URL or any URL under that session), fall back to `/crafting` instead. This prevents the post-delete redirect from landing on the now-404'd session detail page.
- **Delete button is always visible** — the prompt requires Delete to be available regardless of session state (active, processing, archived, done). No conditional visibility logic.

## Open Questions

### Resolved During Planning

- **Should the base query also exclude archived rows?** No. Archived rows are still visible on the archived sessions page; only the deleted filter is universal. The base query filters only `deleted_at`, and `list_workflow_sessions/0` continues to additionally filter `archived_at` while `list_archived_workflow_sessions/0` filters `not is_nil(archived_at)`.
- **Should `delete_workflow_session/1` also clear `service_state`?** Mirror the archive behavior, which does not explicitly clear `service_state` in the changeset (cleanup is performed via `ServiceManager.cleanup/1`, which itself calls `update_workflow_session(ws, %{service_state: nil})`). So `delete_workflow_session/1` should call `ServiceManager.cleanup/1` when `service_state` is present, and the `deleted_at` update can run as a separate changeset call afterward (matching archive's structure).
- **Should we add an index on `deleted_at`?** Yes, for parity with `archived_at` (both are filtered in the hottest read paths). The migration adds `create index(:workflow_sessions, [:deleted_at])`.
- **Should `get_workflow_session!/1` raise or return nil for deleted rows?** It still raises `Ecto.NoResultsError`, but composed on the base query so the error surfaces for deleted rows the same as missing rows. Internal callers that hit `!` are either upstream-protected or only ever load existing rows.
- **Does the `update_workflow_session(id, attrs)` (string-id) overload need to handle deleted rows?** It uses `get_workflow_session!/1`, which now raises for deleted rows. This is acceptable — only system processes call this overload, and they should not be operating on deleted sessions. If a process tries to update a deleted session, raising is the right failure mode.
- **Where does the referer get cleared?** In the LiveView mount, after reading. This avoids stale referer data leaking into other LiveViews' sessions.

### Deferred to Implementation

- **Exact placement of the Delete button** — visually adjacent to Archive/Unarchive in the same controls cluster. Final ordering (left/right of Archive) is a styling choice the implementer can make based on the existing markup.
- **Exact `data-confirm` copy** — something like `"Permanently delete this session? This cannot be undone in the app."`. The implementer can refine the wording.
- **Whether the referer plug is its own pipeline or inline on the route** — implementer can choose whichever fits the router's existing organization. The behavior is identical.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```
                           ┌──────────────────────────────┐
                           │  Destila.Workflows           │
                           │                              │
                           │  base_session_query/0        │  ◄── private, single
                           │    (excludes deleted_at)     │       source of truth
                           │                              │
                           └──────────────┬───────────────┘
                                          │
              ┌───────────────────────────┼───────────────────────────┐
              ▼                           ▼                           ▼
    ┌──────────────────┐        ┌──────────────────┐        ┌──────────────────────────┐
    │ list_workflow_   │        │ list_archived_   │        │ list_sessions_with_      │
    │ sessions/0       │        │ workflow_        │        │ exported_metadata/1      │
    │ (+ archived_at   │        │ sessions/0       │        │ (+ done_at && archived)  │
    │   nil)           │        │ (+ archived_at   │        │                          │
    │                  │        │   not nil)       │        │                          │
    └──────────────────┘        └──────────────────┘        └──────────────────────────┘
              ▼                           ▼                           ▼
       crafting board             archived sessions          source-session selectors
       dashboard                  page                       (via list_source_sessions)

    ┌──────────────────┐        ┌──────────────────┐
    │ get_workflow_    │        │ get_workflow_    │
    │ session/1        │        │ session!/1       │
    │ (returns nil for │        │ (raises for      │
    │  deleted)        │        │  deleted)        │
    └──────────────────┘        └──────────────────┘
              ▼
    WorkflowRunnerLive / AiSessionDetailLive existing 404 redirect

    ┌──────────────────────────────────────────────────────────────┐
    │  count_by_project/1, count_by_projects/0                     │
    │    NOT composed on base query — counts ALL rows incl. deleted │
    └──────────────────────────────────────────────────────────────┘
              ▼
    Destila.Projects.delete_project/1 — keeps blocking deletion

    ┌──────────────────────────────────────────────────────────────┐
    │  delete_workflow_session/1                                    │
    │    1. if service_state → ServiceManager.cleanup(ws)           │
    │    2. ClaudeSession.stop_for_workflow_session(ws.id)          │
    │    3. Session.changeset(%{deleted_at: DateTime.utc_now()})    │
    │       |> Repo.update()                                        │
    │       |> broadcast(:workflow_session_updated)                 │
    └──────────────────────────────────────────────────────────────┘
```

## Implementation Units

- [ ] **Unit 1: Migration and schema**

**Goal:** Add a nullable `deleted_at` UTC datetime column to `workflow_sessions`, with an index, and expose it through the schema's changeset.

**Requirements:** R1

**Dependencies:** None

**Files:**
- Create: `priv/repo/migrations/20260417000000_add_deleted_at_to_workflow_sessions.exs`
- Modify: `lib/destila/workflows/session.ex`

**Approach:**
- Migration uses `alter table(:workflow_sessions) do add :deleted_at, :utc_datetime end` and adds `create index(:workflow_sessions, [:deleted_at])`. No backfill — the column starts null for all existing rows.
- Add `field :deleted_at, :utc_datetime` to the schema, mirroring how `archived_at` is declared.
- Add `:deleted_at` to the changeset's `cast/2` list (same shape as `:archived_at`).

**Patterns to follow:**
- `priv/repo/migrations/20260415000000_add_archived_at_to_projects.exs` — alter-table-add-timestamp pattern.
- `lib/destila/workflows/session.ex:39-56` — changeset cast inclusion for `archived_at`.

**Test scenarios:**
- Test expectation: none — schema and migration are exercised through the context tests in Unit 2 and the LiveView tests in Unit 4.

**Verification:**
- `mix ecto.migrate` runs cleanly.
- The schema struct exposes `deleted_at` and the changeset accepts it.

- [ ] **Unit 2: Workflows context — base query, list filtering, and `delete_workflow_session/1`**

**Goal:** Introduce a shared private base query that excludes deleted rows, compose all read paths on it, and add `delete_workflow_session/1` mirroring `archive_workflow_session/1`. Keep count helpers outside the base query.

**Requirements:** R4, R5, R6, R7, R8

**Dependencies:** Unit 1

**Files:**
- Modify: `lib/destila/workflows.ex`
- Modify: `test/destila/workflow_test.exs` (add the new context tests)
- Modify: `test/destila/workflows_classify_test.exs` (only if any read-path test there needs adjustment — likely none)

**Approach:**
- Introduce a private helper such as `defp base_session_query, do: from(ws in Session, where: is_nil(ws.deleted_at))`.
- Refactor:
  - `list_workflow_sessions/0` → `base_session_query() |> where([ws], is_nil(ws.archived_at)) |> order_by([ws], ws.position) |> preload(:project) |> Repo.all()`.
  - `list_archived_workflow_sessions/0` → `base_session_query() |> where([ws], not is_nil(ws.archived_at)) |> order_by([ws], desc: ws.archived_at) |> preload(:project) |> Repo.all()`.
  - `get_workflow_session/1` → `base_session_query() |> Repo.get(id)`.
  - `get_workflow_session!/1` → `base_session_query() |> Repo.get!(id)`.
  - `list_sessions_with_exported_metadata/1` → composed on the base query, then joined with `SessionMetadata` and existing filters preserved (`not is_nil(ws.done_at) and is_nil(ws.archived_at)`).
- Leave `count_by_project/1` and `count_by_projects/0` unchanged — they keep using `from(ws in Session, ...)` directly.
- Add `delete_workflow_session/1` mirroring `archive_workflow_session/1`:
  ```
  def delete_workflow_session(%Session{} = ws) do
    if ws.service_state, do: Destila.Services.ServiceManager.cleanup(ws)
    Destila.AI.ClaudeSession.stop_for_workflow_session(ws.id)

    ws
    |> Session.changeset(%{deleted_at: DateTime.utc_now()})
    |> Repo.update()
    |> broadcast(:workflow_session_updated)
  end
  ```
- Do not introduce `undelete_workflow_session/1`. Recovery is console-only.

**Patterns to follow:**
- `lib/destila/workflows.ex:206-217` — `archive_workflow_session/1` shape.
- `lib/destila/workflows.ex:64-80` and `170-182` — query composition style.

**Test scenarios:**
- Happy path: `delete_workflow_session/1` sets `deleted_at`, returns `{:ok, %Session{deleted_at: %DateTime{}}}`.
- Happy path: when `ws.service_state` is non-nil, `ServiceManager.cleanup/1` is invoked exactly once (verify via mocking the tmux interface or by asserting `service_state` is cleared post-call, depending on how existing archive tests verify cleanup).
- Happy path: when `ws.service_state` is nil, `ServiceManager.cleanup/1` is not invoked (mirror the archive test's branch coverage).
- Happy path: `ClaudeSession.stop_for_workflow_session/1` is invoked with the workflow session id (verify with the same approach as archive tests).
- Integration: `delete_workflow_session/1` broadcasts `{:workflow_session_updated, %Session{}}` on `"store:updates"` (subscribe in the test, assert_receive).
- Edge case: `list_workflow_sessions/0` excludes deleted sessions.
- Edge case: `list_archived_workflow_sessions/0` excludes deleted sessions (a session that is both archived and deleted does not appear here).
- Edge case: `get_workflow_session/1` returns nil for a deleted session.
- Edge case: `get_workflow_session!/1` raises `Ecto.NoResultsError` for a deleted session.
- Edge case: `list_sessions_with_exported_metadata/1` excludes deleted sessions (insert a deleted session with done_at + exported metadata; assert it does not appear in results).
- Edge case: `count_by_project/1` includes deleted sessions (insert one deleted session for a project; expect count of 1).
- Edge case: `count_by_projects/0` includes deleted sessions in the per-project count.
- Integration: after `delete_workflow_session/1`, calling `Destila.Projects.delete_project/1` on the linked project still returns `{:error, :has_linked_sessions}` (this scenario also covered in Unit 5 Gherkin but worth a unit-level assertion here).

**Verification:**
- All read paths return only non-deleted rows.
- `delete_workflow_session/1` performs cleanup, stop, update, and broadcast in that order.
- Count helpers remain unchanged in behavior for deleted rows.
- Project deletion stays blocked when only deleted sessions are linked.

- [ ] **Unit 3: Router — capture referer for the session detail route**

**Goal:** Make the HTTP referer available to `WorkflowRunnerLive`'s `mount/3` via the session, so the post-delete redirect can return the user to where they came from.

**Requirements:** R3

**Dependencies:** None (independent of Units 1-2; can land in any order before Unit 4)

**Files:**
- Modify: `lib/destila_web/router.ex`

**Approach:**
- Add a small private plug (e.g., `put_session_detail_referer/2`) inside the router. The plug reads `Plug.Conn.get_req_header(conn, "referer")` and, when present, calls `Plug.Conn.put_session(conn, :session_detail_referer, referer)`. When absent, the plug is a no-op.
- Apply the plug only to the `/sessions/:id` route. The simplest mechanism is a one-route pipeline (e.g., `pipeline :session_detail`) `pipe_through`'d on a scope containing only that route. Alternative: inline pipe call. Implementer's choice.
- Do not place the plug in `:browser` — the referer assignment should not leak into every route's session.

**Patterns to follow:**
- `lib/destila_web/router.ex:6-13` — existing `:browser` pipeline structure for plug declaration shape.

**Test scenarios:**
- Test expectation: none at the router level — behavior is exercised end-to-end by the LiveView test in Unit 4 ("Delete redirects to referer when present" and "Delete falls back to /crafting when referer is missing").

**Verification:**
- The session is populated with `:session_detail_referer` only when the request to `/sessions/:id` includes a `Referer` header.

- [ ] **Unit 4: WorkflowRunnerLive — Delete button, handler, and redirect logic**

**Goal:** Render a Delete button next to Archive/Unarchive on the session detail page, wire it through `data-confirm`, and handle the event by calling `Workflows.delete_workflow_session/1` and redirecting.

**Requirements:** R2, R3, R5, R6

**Dependencies:** Units 2 and 3

**Files:**
- Modify: `lib/destila_web/live/workflow_runner_live.ex` (mount + template + handle_event)
- Create: `test/destila_web/live/session_deletion_live_test.exs`

**Approach:**
- In `mount/3`, after the existing `Workflows.get_workflow_session/1` call, capture the referer:
  ```
  referer = Map.get(session, "session_detail_referer") || Map.get(session, :session_detail_referer)
  ```
  Sanitize: if the referer is `nil`, empty, or matches the current session detail URL pattern (`/sessions/<id>` or any URL whose path is under the session being viewed), set the post-delete redirect target to `~p"/crafting"`. Otherwise use the referer.
  Assign as `:post_delete_redirect`.
- In the template, near the existing Archive/Unarchive buttons, add:
  ```
  <button
    :if={@workflow_session}
    phx-click="delete_session"
    id="delete-btn"
    class="btn btn-soft btn-sm"
    data-confirm="Permanently delete this session? This cannot be undone in the app."
  >
    <.icon name="hero-trash-micro" class="size-4" /> Delete
  </button>
  ```
  The button is unconditional on session state — it appears for active, processing, archived, and done sessions.
- Add `handle_event("delete_session", _params, socket)`:
  ```
  {:ok, _ws} = Workflows.delete_workflow_session(socket.assigns.workflow_session)

  {:noreply,
   socket
   |> put_flash(:info, "Session deleted")
   |> push_navigate(to: socket.assigns.post_delete_redirect)}
  ```
- Confirm the existing PubSub `handle_info({:workflow_session_updated, ...}, socket)` handler does not break when the freshly broadcast row is the just-deleted one. Because the LiveView is about to navigate away, this is benign — but verify the handler's `Workflows.get_workflow_session!/1` call (line ~441 in current code) does not raise before the redirect lands. If timing is an issue, the redirect should fire before the broadcast loops back. This is the same situation as the existing archive flow, which already navigates away after broadcast.
- Verify that `AiSessionDetailLive`'s existing not-found redirect handles deleted sessions correctly (no template change needed because `Workflows.get_workflow_session/1` now returns `nil` for deleted rows).

**Patterns to follow:**
- `lib/destila_web/live/workflow_runner_live.ex:107-113` — existing archive `handle_event` (same shape).
- `lib/destila_web/live/workflow_runner_live.ex:720-738` — existing Archive/Unarchive button template (DOM ID, `data-confirm`, button classes, icon component usage).

**Test scenarios:**

- Happy path: clicking the Delete button (verified via `render_click(view, "#delete-btn")`) calls the context function, sets a flash, and pushes navigation. *(In LiveView tests, `data-confirm` is bypassed by `render_click`; verify the attribute exists separately via the rendered HTML.)*
- Happy path: the rendered Delete button has the correct `data-confirm` attribute value (assert presence and exact copy via `LazyHTML` selector or substring match).
- Happy path: after delete, the redirect target is the captured referer when one was present (set up the `LiveView` with a referer in session via the test conn's `init_test_session/2`, click delete, assert the redirect path).
- Happy path: after delete, the redirect target is `~p"/crafting"` when no referer is present.
- Edge case: when the referer points back to the same session detail URL, the redirect falls back to `~p"/crafting"`.
- Edge case: when the referer is an empty string, the redirect falls back to `~p"/crafting"`.
- Edge case: Delete button is rendered for an archived session (mount the LiveView with an archived session, assert `has_element?(view, "#delete-btn")`).
- Edge case: Delete button is rendered for a session in `:processing` state.
- Edge case: Delete button is rendered for a `done?/1` session.
- Integration: navigating directly to `/sessions/<deleted_id>` is redirected with the existing "Session not found" flash (mount with a soft-deleted session id, assert `redirected_to == ~p"/crafting"` and the flash contains "Session not found").
- Integration: the Delete button uses `phx-click="delete_session"` with no custom JS hook (assert no `phx-hook` attribute on the button).

**Verification:**
- Delete button renders for every session state.
- Click → soft-delete, flash, redirect to referer or `/crafting`.
- Direct navigation to a deleted session URL surfaces as the existing 404-style redirect.

- [ ] **Unit 5: Hidden-from-listings tests**

**Goal:** Verify deleted sessions do not appear in any UI listing or selector.

**Requirements:** R4, R7

**Dependencies:** Units 2 and 4

**Files:**
- Modify: `test/destila_web/live/crafting_board_live_test.exs` (add a test that a deleted session is not rendered)
- Modify: `test/destila_web/live/archived_sessions_live_test.exs` (add a test that a deleted+archived session is not rendered)
- Modify or create: a test that confirms `list_source_sessions/1` (which calls `list_sessions_with_exported_metadata/1`) excludes deleted sessions — most efficiently added to `test/destila/workflow_test.exs` as a context-level assertion since `list_source_sessions/1` is a pure context function.
- Modify: `test/destila/projects_test.exs` (or wherever `delete_project/1` is tested) to add a test that project deletion is blocked when only soft-deleted sessions are linked.

**Approach:**
- Use the existing test helpers (`create_session`, `archive_session`) and add a new `delete_session/1` helper inline or in a shared `Destila.WorkflowsFixtures` module if one exists.
- For each LiveView test, mount the LiveView, assert the deleted session's title (or DOM id) is not present.
- For the `list_source_sessions/1` assertion, insert a session with exported metadata + `done_at`, soft-delete it, and assert it does not appear in the result.
- For the project guard, insert a session, soft-delete it, then call `Destila.Projects.delete_project/1` and assert `{:error, :has_linked_sessions}`.

**Patterns to follow:**
- `test/destila_web/live/archived_sessions_live_test.exs:40-101` — listing test shape and helpers.

**Test scenarios:**
- Happy path: a deleted session does not appear on the crafting board.
- Happy path: a deleted session does not appear on the archived sessions page (even if it was archived first then deleted).
- Happy path: a deleted session does not appear in `list_source_sessions/1` output.
- Happy path: project deletion returns `{:error, :has_linked_sessions}` when the only linked session is soft-deleted.

**Verification:**
- All four scenarios pass; no UI surface or source-session selector exposes deleted rows; project deletion guard remains effective.

- [ ] **Unit 6: Gherkin feature file**

**Goal:** Create the feature file documenting the deletion behavior, with all scenarios from the prompt.

**Requirements:** All

**Dependencies:** Units 4 and 5

**Files:**
- Create: `features/session_deletion.feature`

**Approach:**
- Copy the exact 8 scenarios from the prompt (`Delete a session from the session detail page`, `Cancel the delete confirmation dialog`, `Deleted session is hidden from the crafting board`, `Deleted session is hidden from the archived sessions page`, `Deleted session detail page is no longer accessible`, `Delete an archived session`, `Deleting a running session stops its service and AI sessions`, `Deleted sessions still block project deletion`).
- Ensure each test added in Units 4 and 5 carries a matching `@tag feature: "session_deletion", scenario: "..."` annotation. Add `@feature "session_deletion"` module attribute and `@tag feature: @feature, scenario: "..."` per test, mirroring `test/destila_web/live/archived_sessions_live_test.exs` style.
- Verify every scenario in the file has at least one linked test by running `mix test --only feature:session_deletion` and confirming the count matches expectations.

**Patterns to follow:**
- `features/session_archiving.feature` — feature header and scenario style.
- `test/destila_web/live/archived_sessions_live_test.exs:1-30` — `@moduledoc` and `@tag` linking pattern.

**Test scenarios:**
- Test expectation: none — this is a documentation file. The linkage is verified by the `@tag` annotations on the tests in Units 4 and 5.

**Verification:**
- `features/session_deletion.feature` contains all 8 scenarios verbatim from the prompt.
- Every scenario in the feature file has at least one test tagged with the matching scenario name.
- `mix test --only feature:session_deletion` runs the linked tests successfully.

- [ ] **Unit 7: Pre-commit hygiene**

**Goal:** Run the project's pre-commit checks before considering the change done.

**Requirements:** All

**Dependencies:** Units 1-6

**Files:**
- None (CI/lint pass only)

**Approach:**
- Run `mix precommit` and address any pending issues (formatter, compiler warnings, credo if configured, test failures).

**Test scenarios:**
- Test expectation: none — this is a verification-only step.

**Verification:**
- `mix precommit` exits 0.

## System-Wide Impact

- **Interaction graph:**
  - `Destila.Workflows.list_workflow_sessions/0` → `CraftingBoardLive`, `DashboardLive`. Both refetch on `:workflow_session_updated`.
  - `Destila.Workflows.list_archived_workflow_sessions/0` → `ArchivedSessionsLive`. Refetches on `:workflow_session_updated`.
  - `Destila.Workflows.list_sessions_with_exported_metadata/1` → `Destila.Workflows.list_source_sessions/1` → `CreateSessionLive` (source-session selector for workflows that have a `source_metadata_key`).
  - `Destila.Workflows.get_workflow_session/1` → `WorkflowRunnerLive.mount/3`, `AiSessionDetailLive.mount/3`. Both already redirect with a flash when the session is missing.
  - `Destila.Workflows.get_workflow_session!/1` → `WorkflowRunnerLive`'s PubSub handler and `update_workflow_session(id, attrs)` overload. Will raise for deleted rows; acceptable since these paths are not expected to operate on deleted sessions.
  - `Destila.Workflows.count_by_project/1` → `Destila.Projects.delete_project/1`. Continues to count deleted rows (no change).
- **Error propagation:** `delete_workflow_session/1` does not catch service or Claude-session shutdown errors — same as `archive_workflow_session/1`. If those raise, the session does not get its `deleted_at` set; the user sees the standard LiveView error and can retry. This is acceptable parity.
- **State lifecycle risks:**
  - The existing `WorkflowRunnerLive` PubSub handler refetches the session on `:workflow_session_updated` and may briefly attempt `Workflows.get_workflow_session!/1` on the just-deleted row. The handler runs after the LiveView has already issued `push_navigate`, so the user has navigated away by the time the broadcast loops back; if the handler does fire on the still-mounted process, the raise is benign (the LiveView is about to be unmounted). Mirror behavior to archive — same risk profile, no production issue observed.
  - Active phase executions, oban jobs targeting the session, and other background work are not cancelled. They will fail or no-op when they next try to load the session via `get_workflow_session!/1`. This is consistent with the archive flow's behavior and is intentional — soft-delete is metadata-level only.
- **API surface parity:** No external API changes. The internal context surface gains `delete_workflow_session/1` and (privately) `base_session_query/0`.
- **Integration coverage:** Cross-layer scenarios worth the integration tests in Unit 5: deleted session not appearing on three LiveView pages, deleted session not appearing in source-session selector, and project deletion still blocked.
- **Unchanged invariants:**
  - `archive_workflow_session/1`, `unarchive_workflow_session/1` behavior unchanged.
  - `count_by_project/1`, `count_by_projects/0` continue to count all linked sessions (deleted or not).
  - `delete_project/1` semantics unchanged — still returns `{:error, :has_linked_sessions}` whenever any session row references the project.
  - The `:workflow_session_updated` PubSub event remains the single broadcast for any session-row mutation.
  - No new event types, no new endpoints, no new routes.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| A read path is missed and continues to expose deleted sessions. | The base query refactor structurally enforces exclusion at the query level. Unit 5's listing tests cover the four UI surfaces and the source-session selector explicitly. |
| `count_by_project/1` is accidentally composed on the new base query, breaking the project-deletion guard for soft-deleted-only links. | Explicitly listed under "Decisions" and verified by a unit test in Unit 2 and a Gherkin scenario in Unit 6. Reviewer should look for the count helpers staying on raw `from(ws in Session, ...)`. |
| Referer captured points back to the session being deleted, causing the post-delete redirect to land on a 404 page. | Mount-time sanity check falls back to `/crafting` when the captured referer matches the current session detail URL. Unit 4 includes a test for this case. |
| `Workflows.get_workflow_session!/1` raises in the `update_workflow_session(id, attrs)` overload after deletion, breaking background workers. | Background workers operating on a deleted session is the desired failure mode — soft-delete should make those operations no-op via raise. If a specific worker needs graceful handling, that's a separate fix outside this plan's scope. |
| Cleanup helpers (`ServiceManager.cleanup/1`, `ClaudeSession.stop_for_workflow_session/1`) raise unexpectedly during delete. | Mirrors archive's risk profile. No new mitigation required. |

## Documentation / Operational Notes

- Console-only recovery: a deleted session is restored by setting `deleted_at: nil` via the remote shell:
  ```
  iex --sname debug --remsh destila@$(hostname -s)
  Destila.Repo.update_all(
    from(ws in Destila.Workflows.Session, where: ws.id == ^id),
    set: [deleted_at: nil]
  )
  Destila.PubSubHelper.broadcast_event(:workflow_session_updated, Destila.Repo.get!(Destila.Workflows.Session, id))
  ```
  Worth noting in the PR description so the team knows the recovery path.
- No data migration needed — the column starts null for all existing rows.
- No rollout flag — feature is on as soon as deployed.

## Sources & References

- Related code: `lib/destila/workflows.ex` — archive reference implementation and read-path query helpers.
- Related code: `lib/destila_web/live/workflow_runner_live.ex` — session detail LiveView, archive button template, mount + 404 redirect.
- Related code: `lib/destila/services/service_manager.ex`, `lib/destila/ai/claude_session.ex` — cleanup helpers reused by delete.
- Related code: `lib/destila/projects.ex` — project deletion guard that must keep working for soft-deleted sessions.
- Related plan: `docs/plans/2026-04-15-002-feat-project-archiving-plan.md` — pattern reference for adding a soft-flag column to a Phoenix context.
- Related feature: `features/session_archiving.feature` — Gherkin pattern reference.
- Related test: `test/destila_web/live/archived_sessions_live_test.exs` — test linkage and helpers reference.
