# Replace In-Memory ETS Store with SQLite via Ecto

**Date:** 2026-03-22
**Status:** Ready for planning

## What We're Building

A backend infrastructure swap: replace the ETS-based `Destila.Store` GenServer with a SQLite database using Ecto. All three entities (Projects, Prompts, Messages) will be migrated to Ecto schemas with proper changesets, associations, and context modules. The end-user behavior remains identical.

## Why This Approach

The current ETS store loses all data on application restart or crash. There is no data persistence, no migration path, and no query capabilities beyond full-table scans. SQLite provides durable storage with zero operational overhead (no external database process), making it ideal for this single-node application.

## Key Decisions

### 1. Field Persistence Strategy

Prompt maps currently mix persistent and runtime state in ETS. With SQLite:

| Field | Persisted? | Rationale |
|-------|-----------|-----------|
| `id`, `title`, `workflow_type`, `project_id`, `board`, `column`, `position`, `steps_completed`, `steps_total`, `created_at`, `updated_at` | Yes | Core prompt data |
| `phase_status` | Yes | Users must resume workflows after server restarts |
| `title_generating` | Yes | Temporary but must survive restarts to show correct UI state |
| `ai_session` (PID) | No | Runtime-only. Future: add `session_id` string column for Claude Code session resumption |

**Runtime state** (`ai_session` PID) will be managed via LiveView assigns or a separate in-memory mechanism (e.g., process registry), not stored in the database.

### 2. ID Strategy

Transition from custom `:crypto.strong_rand_bytes` 22-char base64url strings to Ecto-idiomatic UUIDs. Use `Ecto.UUID` as the primary key type for all schemas.

### 3. Context Modules

Three context modules following Phoenix conventions:
- `Destila.Projects` — CRUD for projects, with delete guard (cannot delete if linked prompts exist)
- `Destila.Prompts` — CRUD for prompts, including `move_card/3` convenience function
- `Destila.Messages` — create/list messages for a prompt

Each broadcasts on the existing `"store:updates"` PubSub topic with the same message shapes.

### 4. Validation Centralization

Move validation from LiveViews into Ecto changesets:
- **Project**: requires `name`, at least one of `git_repo_url` or `local_folder`
- **Prompt**: requires `title`, `workflow_type`, `board`, `column`
- **Message**: requires `prompt_id`, `role`, `content`

### 5. Seeds Removal

Delete `Destila.Seeds` entirely. The database starts empty. Seed data was only useful for development demos and complicates testing.

### 6. Test Strategy

- Configure `Ecto.Adapters.SQL.Sandbox` for test isolation
- All tests create their own data via context modules
- Remove reliance on shared seed data
- Tests can use `async: true` where possible (sandbox allows it)

## Scope

### In Scope
- Add `ecto_sql` and `ecto_sqlite3` dependencies
- Create `Destila.Repo` and add to supervision tree
- Single migration for all three tables
- Ecto schemas with changesets and associations
- Three context modules with PubSub broadcasting
- Update all LiveView callers and `ChoreTaskPhases`
- Update all tests for Ecto sandbox
- Remove `Destila.Store`, `Destila.Seeds`, and supervision tree entry

### Out of Scope
- Session persistence / Claude Code session ID tracking (future work)
- Any UI changes
- Feature file modifications (all 35 scenarios must continue passing)
