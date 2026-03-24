---
title: "feat: Archive and Unarchive Workflow Sessions"
type: feat
date: 2026-03-24
---

# Archive and Unarchive Workflow Sessions

## Overview

Add soft-delete archiving for workflow sessions. Archiving hides sessions from the crafting board and dashboard while preserving all data. Users can restore archived sessions at any time. A dedicated archived sessions page lists all archived sessions.

## Problem Statement

As the number of workflow sessions grows, the crafting board and dashboard become cluttered with completed or abandoned sessions. Users need a way to declutter their workspace without permanently losing session data.

## Proposed Solution

Add an `archived_at` (UTC datetime, nullable) field to the `WorkflowSession` schema. A non-null value means the session is archived. Filter archived sessions from the crafting board and dashboard by default. Provide an archive/unarchive toggle on the session detail page and a dedicated page to browse archived sessions.

## Technical Approach

### 1. Schema & Migration

**File:** `lib/destila/workflow_sessions/workflow_session.ex`

Add `archived_at` field to the schema and changeset:

```elixir
field(:archived_at, :utc_datetime)
```

Cast `:archived_at` in the changeset's `cast/3` field list.

**Migration:** Since the app is early-stage, reset the DB. Add `archived_at` to the `create table(:workflow_sessions)` block in the existing migration:

```elixir
add :archived_at, :utc_datetime
```

### 2. Context Functions

**File:** `lib/destila/workflow_sessions.ex`

**Modify `list_workflow_sessions/0`** to exclude archived sessions:

```elixir
def list_workflow_sessions do
  from(ws in WorkflowSession,
    where: is_nil(ws.archived_at),
    order_by: ws.position
  )
  |> preload(:project)
  |> Repo.all()
end
```

**Add `list_archived_workflow_sessions/0`** for the archived page:

```elixir
def list_archived_workflow_sessions do
  from(ws in WorkflowSession,
    where: not is_nil(ws.archived_at),
    order_by: [desc: ws.archived_at]
  )
  |> preload(:project)
  |> Repo.all()
end
```

**Add `archive_workflow_session/1`** — sets `archived_at` and stops the AI GenServer:

```elixir
def archive_workflow_session(%WorkflowSession{} = ws) do
  stop_ai_session(ws.id)

  ws
  |> WorkflowSession.changeset(%{archived_at: DateTime.utc_now()})
  |> Repo.update()
  |> broadcast(:workflow_session_updated)
end
```

**Add `unarchive_workflow_session/1`** — clears `archived_at`:

```elixir
def unarchive_workflow_session(%WorkflowSession{} = ws) do
  ws
  |> WorkflowSession.changeset(%{archived_at: nil})
  |> Repo.update()
  |> broadcast(:workflow_session_updated)
end
```

**Add `stop_ai_session/1`** private helper:

```elixir
defp stop_ai_session(workflow_session_id) do
  name = {:via, Registry, {Destila.AI.SessionRegistry, workflow_session_id}}

  case GenServer.whereis(name) do
    nil -> :ok
    pid -> Destila.AI.Session.stop(pid)
  end
end
```

**Leave `count_by_project/1` and `count_by_projects/0` unchanged** — archived sessions still count toward project totals and block project deletion.

### 3. Session Detail Page — Archive/Unarchive Button

**File:** `lib/destila_web/live/session_detail_live.ex`

**Add event handlers:**

```elixir
def handle_event("archive_session", _params, socket) do
  {:ok, ws} = Destila.WorkflowSessions.archive_workflow_session(socket.assigns.workflow_session)

  {:noreply,
   socket
   |> assign(:workflow_session, ws)
   |> put_flash(:info, "Session archived")}
end

def handle_event("unarchive_session", _params, socket) do
  {:ok, ws} = Destila.WorkflowSessions.unarchive_workflow_session(socket.assigns.workflow_session)

  {:noreply,
   socket
   |> assign(:workflow_session, ws)
   |> put_flash(:info, "Session restored")}
end
```

**Add button in the header** (next to the "Mark as Done" button area):

```heex
<button
  :if={is_nil(@workflow_session.archived_at)}
  phx-click="archive_session"
  id="archive-btn"
  class="btn btn-ghost btn-sm"
  data-confirm="Archive this session? It will be hidden from the crafting board."
>
  <.icon name="hero-archive-box-micro" class="size-4" /> Archive
</button>
<button
  :if={@workflow_session.archived_at}
  phx-click="unarchive_session"
  id="unarchive-btn"
  class="btn btn-ghost btn-sm"
>
  <.icon name="hero-archive-box-arrow-down-micro" class="size-4" /> Unarchive
</button>
```

### 4. Archived Sessions Page

**File:** `lib/destila_web/live/archived_sessions_live.ex` (new)

A simple LiveView listing all archived sessions with title, project name, and workflow type. Each row links to the session detail page. Shows an empty-state message when no sessions are archived.

Subscribes to `"store:updates"` PubSub and refetches on `:workflow_session_updated` to reflect unarchive actions in real time.

**Route:** Add to the authenticated scope in `lib/destila_web/router.ex`:

```elixir
live "/sessions/archived", ArchivedSessionsLive
```

Place this route **before** `live "/sessions/:id", SessionDetailLive` to avoid the `:id` param capturing "archived" as an ID.

### 5. Crafting Board — "View Archived" Link

**File:** `lib/destila_web/live/crafting_board_live.ex`

Add a subtle link in the header area (near the "New Session" button or below the view controls):

```heex
<.link navigate={~p"/sessions/archived"} class="text-xs text-base-content/40 hover:text-base-content/60 transition-colors">
  View archived
</.link>
```

### 6. PubSub — No Changes Needed

Both `archive_workflow_session/1` and `unarchive_workflow_session/1` broadcast `:workflow_session_updated` via the existing `broadcast/2` helper. The crafting board and dashboard already handle this event by refetching via `list_workflow_sessions/0`, which will now exclude archived sessions. No new PubSub events or handlers needed.

### 7. AI Session GenServer — Stopped on Archive

When a session is archived, `stop_ai_session/1` checks the Registry for a running GenServer and stops it gracefully. This frees resources immediately rather than waiting for the 5-minute inactivity timeout. On unarchive, the GenServer restarts naturally when the user next interacts with the session (via `for_workflow_session/2`).

## Acceptance Criteria

- [x] `archived_at` field added to WorkflowSession schema and migration
- [x] `list_workflow_sessions/0` excludes archived sessions
- [x] `list_archived_workflow_sessions/0` returns only archived sessions ordered by `archived_at` desc
- [x] `archive_workflow_session/1` sets `archived_at`, stops AI GenServer, broadcasts update
- [x] `unarchive_workflow_session/1` clears `archived_at`, broadcasts update
- [x] `count_by_project/1` still counts archived sessions (no filter change)
- [x] Session detail page shows "Archive" button for active sessions
- [x] Session detail page shows "Unarchive" button for archived sessions
- [x] Flash messages confirm archive/unarchive actions
- [x] Archived sessions hidden from crafting board (both list and workflow views)
- [x] Archived sessions hidden from dashboard
- [x] Archived sessions page at `/sessions/archived` lists all archived sessions
- [x] Archived sessions page shows title, project, workflow type per session
- [x] Archived sessions page shows empty state when none archived
- [x] Clicking a session on the archived page navigates to its detail page
- [x] "View archived" link on crafting board navigates to archived page
- [x] PubSub updates reflect archive/unarchive in real time on crafting board and dashboard
- [x] Gherkin feature file created at `features/session_archiving.feature`
- [x] Tests link to Gherkin scenarios via `@tag feature:` and `@tag scenario:`

## Files to Create or Modify

| File | Action | Purpose |
|------|--------|---------|
| `lib/destila/workflow_sessions/workflow_session.ex` | Modify | Add `archived_at` field and cast |
| `lib/destila/workflow_sessions.ex` | Modify | Add archive/unarchive functions, filter `list_workflow_sessions` |
| `lib/destila_web/live/session_detail_live.ex` | Modify | Add archive/unarchive button and event handlers |
| `lib/destila_web/live/archived_sessions_live.ex` | Create | New LiveView for archived sessions page |
| `lib/destila_web/live/crafting_board_live.ex` | Modify | Add "View archived" link |
| `lib/destila_web/router.ex` | Modify | Add `/sessions/archived` route |
| `priv/repo/migrations/*_create_workflow_sessions.exs` | Modify | Add `archived_at` column (DB reset) |
| `features/session_archiving.feature` | Create | Gherkin scenarios |
| `test/destila_web/live/session_detail_live_test.exs` | Modify | Add archive/unarchive tests |
| `test/destila_web/live/archived_sessions_live_test.exs` | Create | Tests for archived sessions page |
| `test/destila_web/live/crafting_board_live_test.exs` | Modify | Test that archived sessions are hidden |
| `test/destila_web/live/dashboard_live_test.exs` | Modify | Test that archived sessions are hidden |

## Gherkin Feature File

Create `features/session_archiving.feature` with the scenarios from the implementation prompt (provided in the feature description).

## Dependencies & Risks

- **DB reset required** — early-stage app, so this is acceptable per project conventions
- **Route ordering** — `/sessions/archived` must be defined before `/sessions/:id` to avoid Phoenix matching "archived" as a session ID
- **No data loss risk** — archiving only sets a timestamp, all session data preserved
