---
title: "refactor: Remove user authentication for single-user app"
type: refactor
date: 2026-04-09
---

# refactor: Remove user authentication for single-user app

## Overview

The app was generated with a SaaS-style authentication scaffold (login page, session controller, auth plug, user display in sidebar) but is actually a single-user local application. The entire user/auth concept should be removed: login page, sign-out, session-based auth checks, user avatar/name in sidebar, and the `current_user` plumbing threaded through every LiveView.

There is no database-backed User schema — the current "user" is an in-memory map stored in a cookie session. No migrations are needed and no dependencies need removal.

## Current state

### Auth infrastructure (to be deleted)

| File | Purpose |
|------|---------|
| `lib/destila_web/plugs/require_auth.ex` | Plug that checks `current_user` in session, redirects to `/login` |
| `lib/destila_web/controllers/session_controller.ex` | `create` builds in-memory user map, stores in session; `delete` clears session |
| `lib/destila_web/live/session_live.ex` | Login page LiveView at `/login` |

### Router auth structure (`lib/destila_web/router.ex`)

- **Lines 15-17**: `:require_auth` pipeline definition
- **Lines 19-26**: Public scope with `/login` (live + post) and `/logout` routes
- **Lines 29-33**: Oban dashboard pipes through `:require_auth`
- **Lines 36-47**: Main app scope pipes through `:require_auth`

### `current_user` threading through LiveViews

Every LiveView extracts `current_user` from the session in `mount/3` and passes it to `<Layouts.app>`:

| File | Mount line | Template line |
|------|-----------|---------------|
| `lib/destila_web/live/dashboard_live.ex` | 11, 16 | 57 (also displays `@current_user.name` at line 60) |
| `lib/destila_web/live/crafting_board_live.ex` | 24 | 211 |
| `lib/destila_web/live/projects_live.ex` | 13 | 232 |
| `lib/destila_web/live/create_session_live.ex` | 13 | 188, 227 |
| `lib/destila_web/live/archived_sessions_live.ex` | 15 | 33 |
| `lib/destila_web/live/workflow_runner_live.ex` | 26 | 429 |

### Layout user section (`lib/destila_web/components/layouts.ex`)

- **Line 7**: `attr :current_user, :map, default: nil`
- **Line 14**: `<.sidebar :if={@current_user}>` — sidebar only shows when logged in
- **Line 18**: `@current_user && "ml-16 sidebar-open:ml-60"` — margin conditional
- **Lines 28, 74-90**: Sidebar user section — avatar circle with first letter, name, "Sign out" link

### Tests (12 files)

Every LiveView test has `conn = post(conn, "/login", %{"email" => "test@example.com"})` in its setup block. These lines must be removed.

## Key design decisions

### 1. Remove auth entirely, don't replace with a simpler mechanism

Since this is a single-user local app, there is no need for any auth substitute. All routes become public. The sidebar always renders. No session cookie is needed for user identity.

### 2. Remove `current_user` attr from `Layouts.app`, always show sidebar

The `Layouts.app` component currently conditionally shows the sidebar based on `current_user`. After this change, the sidebar always renders (no `:if` guard), and the `current_user` attr is removed entirely. The margin class becomes unconditional.

### 3. Replace user section in sidebar with app branding or remove it

The sidebar bottom section currently shows user avatar + name + "Sign out". This should be replaced: remove the user/sign-out block entirely, keep only the theme toggle and sidebar collapse button.

### 4. Dashboard greeting becomes generic

`dashboard_live.ex` line 60 shows "Welcome back, {@current_user.name}". Replace with a simpler heading like "Dashboard" or "Welcome back" without a name.

### 5. Tests drop the login setup line

All 12 test files have a `post(conn, "/login", ...)` line in setup. These lines are simply removed — the conn from the ConnCase setup is used directly.

## Implementation plan

### Step 1: Delete auth files

Delete these three files entirely:
- `lib/destila_web/plugs/require_auth.ex`
- `lib/destila_web/controllers/session_controller.ex`
- `lib/destila_web/live/session_live.ex`

### Step 2: Simplify router

**File:** `lib/destila_web/router.ex`

Remove:
- The `:require_auth` pipeline (lines 15-17)
- The public scope with login/logout routes (lines 19-26)
- `:require_auth` from the Oban dashboard pipe_through (line 30)
- `:require_auth` from the main scope pipe_through (line 37)

The router should collapse to a single browser scope containing all routes (Oban dashboard, dashboard, crafting, projects, workflows, sessions, media).

After:
```elixir
defmodule DestilaWeb.Router do
  use DestilaWeb, :router

  import Oban.Web.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DestilaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/" do
    pipe_through :browser

    oban_dashboard("/oban")
  end

  scope "/", DestilaWeb do
    pipe_through :browser

    live "/", DashboardLive
    live "/crafting", CraftingBoardLive
    live "/projects", ProjectsLive
    live "/workflows", CreateSessionLive
    live "/workflows/:workflow_type", CreateSessionLive
    live "/sessions/archived", ArchivedSessionsLive
    get "/media/:id", MediaController, :show
    live "/sessions/:id", WorkflowRunnerLive
  end
end
```

### Step 3: Update Layouts component

**File:** `lib/destila_web/components/layouts.ex`

In `app/1`:
- Remove `attr :current_user, :map, default: nil`
- Change `<.sidebar :if={@current_user} current_user={@current_user} page_title={@page_title} />` to `<.sidebar page_title={@page_title} />`
- Change margin class from `@current_user && "ml-16 sidebar-open:ml-60"` to just `"ml-16 sidebar-open:ml-60"`

In `sidebar/1`:
- Remove `attr :current_user, :map, required: true`
- Remove the entire user section (lines 74-90: avatar circle, name, sign-out link), keeping the theme toggle and sidebar collapse button

### Step 4: Update all LiveViews — remove current_user plumbing

For each of these 6 LiveViews, make two changes:

1. **Remove** the `assign(:current_user, session["current_user"])` line from `mount/3`
2. **Remove** `current_user={@current_user}` from the `<Layouts.app>` call in `render/1`

Files and specific changes:

**`lib/destila_web/live/dashboard_live.ex`:**
- Remove line 11: `current_user = session["current_user"]`
- Remove line 16: `|> assign(:current_user, current_user)`
- Line 57: `<Layouts.app flash={@flash} current_user={@current_user} ...>` → `<Layouts.app flash={@flash} ...>`
- Line 59-61: Replace "Welcome back, {@current_user.name}" with "Dashboard" or "Welcome back"

**`lib/destila_web/live/crafting_board_live.ex`:**
- Remove line 24: `|> assign(:current_user, session["current_user"])`
- Line 211: Remove `current_user={@current_user}` from `<Layouts.app>`

**`lib/destila_web/live/projects_live.ex`:**
- Remove line 13: `|> assign(:current_user, session["current_user"])`
- Line 232: Remove `current_user={@current_user}` from `<Layouts.app>`

**`lib/destila_web/live/create_session_live.ex`:**
- Remove line 13: `socket = assign(socket, :current_user, session["current_user"])`
- Lines 188, 227: Remove `current_user={@current_user}` from both `<Layouts.app>` calls

**`lib/destila_web/live/archived_sessions_live.ex`:**
- Remove line 15: `|> assign(:current_user, session["current_user"])`
- Line 33: Remove `current_user={@current_user}` from `<Layouts.app>`

**`lib/destila_web/live/workflow_runner_live.ex`:**
- Remove line 26: `socket = assign(socket, :current_user, session["current_user"])`
- Line 429: Remove `current_user={@current_user}` from `<Layouts.app>`

### Step 5: Update tests — remove login setup

In all 12 test files, remove the `conn = post(conn, "/login", %{"email" => "test@example.com"})` line from the setup block:

- `test/destila_web/live/archived_sessions_live_test.exs`
- `test/destila_web/live/brainstorm_idea_workflow_live_test.exs`
- `test/destila_web/live/code_chat_workflow_live_test.exs`
- `test/destila_web/live/crafting_board_live_test.exs`
- `test/destila_web/live/implement_general_prompt_workflow_live_test.exs`
- `test/destila_web/live/markdown_metadata_viewing_live_test.exs`
- `test/destila_web/live/project_inline_creation_live_test.exs`
- `test/destila_web/live/projects_live_test.exs`
- `test/destila_web/live/session_archiving_live_test.exs`
- `test/destila_web/live/user_prompt_sidebar_live_test.exs`
- `test/destila_web/live/video_metadata_viewing_live_test.exs`
- `test/destila_web/live/workflow_type_selection_live_test.exs`

### Step 6: Clean up ConnCase

**File:** `test/support/conn_case.ex`

No changes needed — ConnCase doesn't have any auth helpers. It just provides a clean `conn`.

### Step 7: Clean up session plugs in endpoint (optional, keep)

**File:** `lib/destila_web/endpoint.ex`

Keep `:fetch_session` in the browser pipeline — it's still used by Phoenix LiveView for CSRF and flash. The cookie session infrastructure has no auth cost.

### Step 8: Verify with `mix precommit`

Run `mix precommit` to catch:
- Compilation warnings about unused variables (`session` param in mount may generate warnings if no longer used — keep the param name as `_session` where it's unused)
- Test failures
- Dialyzer/credo issues

## Files changed summary

| Action | File |
|--------|------|
| **Delete** | `lib/destila_web/plugs/require_auth.ex` |
| **Delete** | `lib/destila_web/controllers/session_controller.ex` |
| **Delete** | `lib/destila_web/live/session_live.ex` |
| **Edit** | `lib/destila_web/router.ex` |
| **Edit** | `lib/destila_web/components/layouts.ex` |
| **Edit** | `lib/destila_web/live/dashboard_live.ex` |
| **Edit** | `lib/destila_web/live/crafting_board_live.ex` |
| **Edit** | `lib/destila_web/live/projects_live.ex` |
| **Edit** | `lib/destila_web/live/create_session_live.ex` |
| **Edit** | `lib/destila_web/live/archived_sessions_live.ex` |
| **Edit** | `lib/destila_web/live/workflow_runner_live.ex` |
| **Edit** | 12 test files (remove login setup line) |

## Risks and considerations

- **No database changes**: The user was never persisted — purely in-memory session data. No migration needed.
- **No dependency removal**: No auth libraries in mix.exs.
- **Oban Web dashboard**: Currently behind auth. After this change it becomes publicly accessible on the local network. Acceptable for a single-user local app.
- **Session cookie**: `fetch_session` plug remains for LiveView infrastructure (CSRF, flash). No harm in keeping it.
- **LiveView `mount/3` signature**: The `session` parameter is still passed by Phoenix. Where a LiveView no longer reads anything from it, rename to `_session` to avoid compiler warnings.
