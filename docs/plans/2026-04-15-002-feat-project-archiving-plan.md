---
title: "feat: Add project archiving"
type: feat
status: completed
date: 2026-04-15
---

# feat: Add project archiving

## Overview

Add an `archived_at` timestamp to projects, mirroring the session archiving pattern. Archived projects are hidden from the projects page and session creation project selector. A dedicated archived projects page at `/projects/archived` lets users view and restore archived projects. Archiving has no effect on linked sessions.

## Problem Frame

Projects with linked sessions cannot be deleted, so users have no way to hide projects they no longer actively use. Archiving provides a non-destructive way to remove clutter from the projects list and session creation flow without losing data or affecting linked sessions.

## Requirements Trace

- R1. Add `archived_at` nullable UTC datetime field to projects
- R2. `list_projects/0` excludes archived projects (affects projects page and session creation selector)
- R3. Archive button on each project card with confirmation, removes project from list with flash
- R4. Dedicated archived projects page at `/projects/archived` with unarchive buttons
- R5. Unarchiving restores project to the active list with flash
- R6. Archiving a project does not cascade to its sessions — they remain active
- R7. Real-time updates via PubSub when projects are archived/unarchived
- R8. Empty state on archived projects page when no projects are archived

## Scope Boundaries

- No cascading archive/unarchive to linked sessions
- No cleanup of services or AI sessions (unlike session archiving, projects have no running processes)
- No changes to `delete_project/1` behavior — it still blocks on linked sessions regardless of archive status
- No sidebar navigation changes — the archived projects page is linked from the projects page header, matching how the crafting board links to archived sessions

## Context & Research

### Relevant Code and Patterns

- `lib/destila/workflows.ex:206-231` — `archive_workflow_session/1` and `unarchive_workflow_session/1` are the reference implementations
- `lib/destila/workflows.ex:16-30` — `list_workflow_sessions/0` and `list_archived_workflow_sessions/0` show the query filtering pattern
- `lib/destila_web/live/archived_sessions_live.ex` — reference for the archived items page (plain assigns, PubSub subscription, empty state, back navigation link)
- `lib/destila_web/live/projects_live.ex` — current projects page using streams, PubSub handlers that refetch and reset
- `lib/destila_web/live/crafting_board_live.ex:216-218` — "Archived" button pattern in page header
- `lib/destila/pub_sub_helper.ex` — `broadcast/2` pipes `{:ok, entity}` results, `broadcast_event/2` for standalone events
- `lib/destila_web/components/project_components.ex` — `project_selector/1` used by `CreateSessionLive`

### Institutional Learnings

- When adding `archived_at` to a schema, every listing query must be audited for the filter — a secondary query (`list_sessions_with_generated_prompts/0`) was missed in the session archiving implementation (see `docs/plans/2026-03-31-feat-exclude-archived-sessions-from-prompt-reuse-plan.md`)
- Post-archive navigation: redirect away from the archived entity with a flash message; unarchive keeps the user on the current page
- Project archiving is simpler than session archiving — no service cleanup, no AI session stop, no phase execution state transitions needed

## Key Technical Decisions

- **Reuse `:project_updated` broadcast event**: Archive and unarchive are field updates on the project, so they naturally produce `:project_updated` events. No new event types needed. All existing PubSub handlers in `ProjectsLive` already refetch on `:project_updated`.
- **ArchivedProjectsLive uses plain assigns, not streams**: Matches the `ArchivedSessionsLive` pattern. The archived list is expected to be small and is fully re-fetched on PubSub events.
- **Archive button with two-step confirmation**: Matches the delete confirmation pattern in `ProjectsLive` (click archive → button transforms to confirm/cancel) rather than `data-confirm` dialog. This is consistent with the existing project card interaction model.
- **No sidebar link for archived projects**: The link to `/projects/archived` goes in the `ProjectsLive` header, matching how `CraftingBoardLive` links to `/sessions/archived`.
- **Unarchive on list page, not detail page**: Unlike session archiving where unarchive lives on the session detail page (`WorkflowRunnerLive`), project unarchive is on the `ArchivedProjectsLive` list page because projects have no individual detail page. The `ArchivedProjectsLive` page follows `ArchivedSessionsLive` for page structure (plain assigns, PubSub, empty state) but adds unarchive buttons that the session equivalent does not have.
- **`list_projects/0` name preserved**: Updated to filter `is_nil(archived_at)` — all callers expect only active projects.

## Open Questions

### Resolved During Planning

- **Should archiving block if the project has active sessions?** No — the prompt explicitly states archiving has no effect on linked sessions. Sessions remain active and visible.
- **Should `count_by_projects` include archived sessions?** Not changing — it counts all sessions regardless of archive status, which is the existing behavior and used for display purposes.

### Deferred to Implementation

- **Exact confirmation button styling**: Will be determined by matching the existing delete confirmation pattern in `ProjectsLive`.

## Implementation Units

- [ ] **Unit 1: Migration and schema**

**Goal:** Add `archived_at` field to the projects table and schema.

**Requirements:** R1

**Dependencies:** None

**Files:**
- Create: `priv/repo/migrations/20260415000000_add_archived_at_to_projects.exs`
- Modify: `lib/destila/projects/project.ex`

**Approach:**
- Create an ALTER TABLE migration adding `archived_at :utc_datetime` nullable column and an index on `projects.archived_at`
- Add the field to the `Project` schema and include it in the changeset's cast list
- The field declaration and index are similar to those in migration `20260324111938`, but this migration uses `alter/2` (not `create/3`) since the projects table already exists

**Patterns to follow:**
- `lib/destila/workflows/session.ex` — `archived_at` field declaration and changeset inclusion

**Test expectation:** None — schema and migration are verified through integration tests in later units.

**Verification:**
- Migration runs cleanly with `mix ecto.migrate`
- `Project` schema includes `archived_at` field

- [ ] **Unit 2: Context functions**

**Goal:** Add archive/unarchive/list functions to `Destila.Projects` and update `list_projects/0` to exclude archived projects.

**Requirements:** R1, R2, R6

**Dependencies:** Unit 1

**Files:**
- Modify: `lib/destila/projects.ex`

**Approach:**
- Update `list_projects/0` to add `where: is_nil(p.archived_at)` to the query
- Add `list_archived_projects/0` returning projects where `not is_nil(p.archived_at)`, ordered by `desc: p.archived_at`
- Add `archive_project/1` that sets `archived_at: DateTime.utc_now()` via changeset and pipes through `broadcast(:project_updated)`
- Add `unarchive_project/1` that sets `archived_at: nil` via changeset and pipes through `broadcast(:project_updated)`

**Patterns to follow:**
- `lib/destila/workflows.ex:16-30` — list/list_archived query pattern
- `lib/destila/workflows.ex:206-231` — archive/unarchive functions (but simpler: no service cleanup)

**Test scenarios:**
- Happy path: `list_projects/0` returns only non-archived projects
- Happy path: `list_archived_projects/0` returns only archived projects ordered by `archived_at` desc
- Happy path: `archive_project/1` sets `archived_at` and returns `{:ok, project}`
- Happy path: `unarchive_project/1` clears `archived_at` and returns `{:ok, project}`
- Edge case: `list_projects/0` returns empty list when all projects are archived
- Edge case: `list_archived_projects/0` returns empty list when no projects are archived
- Integration: archiving broadcasts `:project_updated` event
- Integration: unarchiving broadcasts `:project_updated` event

**Verification:**
- `list_projects/0` excludes archived projects
- Archive and unarchive round-trip correctly
- Broadcasts fire on both operations

- [ ] **Unit 3: Archive button on projects page**

**Goal:** Add archive button to each project card and handle the archive event with confirmation.

**Requirements:** R3, R7

**Dependencies:** Unit 2

**Files:**
- Modify: `lib/destila_web/live/projects_live.ex`

**Approach:**
- Add an archive button (archive-box icon) next to the edit and delete buttons on each project card
- Use the same two-step confirmation pattern as delete: `confirm_archive` event sets `@archive_confirming_id`, then `archive_project` event executes the archive
- `confirm_archive` must clear `@delete_confirming_id` and `@editing_project_id` (and vice versa: `confirm_delete` and `edit_project` must clear `@archive_confirming_id`) to ensure only one interactive state is active at a time
- Update the existing `handle_event("cancel", ...)` to also call `maybe_restream_project(socket.assigns.archive_confirming_id)` and `assign(:archive_confirming_id, nil)`, following the same pattern as `delete_confirming_id`
- On successful archive, show flash `"Project archived"` — no redirect needed since the project disappears from the stream automatically via the PubSub handler
- Add `@archive_confirming_id` assign initialized to `nil` in mount
- DOM IDs: `archive-project-{id}`, `confirm-archive-{id}`

**Patterns to follow:**
- `lib/destila_web/live/projects_live.ex:55-86` — delete confirmation pattern (`confirm_delete` → `delete_project`)

**Test scenarios:**
- Happy path: clicking archive button shows confirmation, confirming archives the project and shows flash
- Happy path: archived project disappears from the projects list
- Edge case: canceling archive confirmation returns to normal card state
- Integration: archiving via PubSub causes other connected clients to see the project removed

**Verification:**
- Archive button appears on each project card
- Two-step confirmation works
- Flash message displays after archiving
- Project disappears from the list

- [ ] **Unit 4: Archived projects link in projects page header**

**Goal:** Add an "Archived" navigation button in the projects page header.

**Requirements:** R4

**Dependencies:** Unit 3

**Files:**
- Modify: `lib/destila_web/live/projects_live.ex`

**Approach:**
- Add a `.link navigate={~p"/projects/archived"}` button with `hero-archive-box-micro` icon in the header area, matching the pattern from `CraftingBoardLive`
- Place it before the "New Project" button

**Patterns to follow:**
- `lib/destila_web/live/crafting_board_live.ex:216-218` — "Archived" link button styling

**Test scenarios:**
- Happy path: archived link is visible on the projects page and navigates to `/projects/archived`

**Verification:**
- Link renders in the header with correct href

- [ ] **Unit 5: Archived projects page and route**

**Goal:** Create `ArchivedProjectsLive` page at `/projects/archived` with unarchive functionality.

**Requirements:** R4, R5, R7, R8

**Dependencies:** Unit 2

**Files:**
- Create: `lib/destila_web/live/archived_projects_live.ex`
- Modify: `lib/destila_web/router.ex`
- Create: `test/destila_web/live/archived_projects_live_test.exs`
- Create: `test/destila_web/live/project_archiving_live_test.exs`

**Approach:**
- Create `ArchivedProjectsLive` following the `ArchivedSessionsLive` pattern: plain `@projects` assign, PubSub subscription, re-fetch on `:project_created`/`:project_updated`/`:project_deleted` events
- Header with "Archived Projects" title and "Back to Projects" link (matching the "Back to Crafting Board" pattern)
- Each archived project card shows name, git_repo_url (if present), local_folder (if present), and linked session count — matching the active project card fields but with an unarchive button instead of edit/delete buttons
- Unarchive button calls `unarchive_project/1`, shows flash `"Project restored"`, project disappears from the archived list via PubSub re-fetch
- Empty state with `#archived-empty` div when no projects are archived
- DOM IDs: `archived-list`, `archived-empty`, `archived-project-{id}`, `unarchive-project-{id}`
- Route: add `live "/projects/archived", ArchivedProjectsLive` in the router, placed above the `/projects` route to avoid any future catch-all conflicts

**Patterns to follow:**
- `lib/destila_web/live/archived_sessions_live.ex` — page structure, PubSub handling, empty state, back link

**Test scenarios (archived_projects_live_test.exs):**
- Happy path: archived projects page lists archived projects
- Happy path: empty state message when no projects are archived
- Happy path: back link navigates to projects page
- Edge case: non-archived projects do not appear on the archived page
- Integration: unarchiving from another client removes the project from the archived list via PubSub

**Test scenarios (project_archiving_live_test.exs):**
- Happy path: archive a project from the projects page — confirmation, flash, project removed from list
- Happy path: unarchive a project from the archived page — flash, project removed from archived list
- Happy path: restored project reappears on the projects page
- Happy path: archived project not shown in session creation project selector
- Happy path: archiving a project does not affect its linked sessions on the crafting board
- Edge case: cancel archive confirmation returns to normal state

**Verification:**
- Archived projects page renders at `/projects/archived`
- Unarchive works and shows flash
- Empty state displays when appropriate
- Route does not conflict with other project routes

- [ ] **Unit 6: Gherkin feature file**

**Goal:** Create the Gherkin feature file for project archiving scenarios.

**Requirements:** All

**Dependencies:** Units 3-5

**Files:**
- Create: `features/project_archiving.feature`

**Approach:**
- Write the 7 Gherkin scenarios from the requirements
- Ensure all tests created in Units 3-5 are tagged with `@tag feature: "project_archiving"` and linked to scenario names

**Patterns to follow:**
- `features/session_archiving.feature` — scenario structure and naming
- `features/project_management.feature` — project-specific scenario conventions

**Test expectation:** None — this is a documentation file. Test linking is verified by the `@tag` annotations in the test files from Unit 5.

**Verification:**
- Feature file exists with all 7 scenarios
- Every test in the archiving test files has `@tag feature: "project_archiving", scenario: "..."` matching a scenario name

## System-Wide Impact

- **Interaction graph:** `list_projects/0` is called by `ProjectsLive` (mount + all PubSub handlers) and `CreateSessionLive` (mount + project creation callback). Adding the `is_nil(archived_at)` filter affects all these call sites, which is the desired behavior.
- **Error propagation:** Archive/unarchive are simple field updates — no failure modes beyond Ecto validation. Broadcasts use the existing `:project_updated` event which all project-subscribing LiveViews already handle.
- **State lifecycle risks:** None. No services or processes are associated with projects directly. Archiving is a pure data operation.
- **API surface parity:** The archived projects page mirrors `ArchivedSessionsLive`. The archive button mirrors the delete confirmation pattern in `ProjectsLive`.
- **Integration coverage:** The key integration point is that `CreateSessionLive` calls `list_projects/0` — a test should verify archived projects don't appear in the session creation project selector.
- **Unchanged invariants:** `delete_project/1` behavior is unchanged — it still checks `count_by_project` and blocks deletion when sessions are linked. `count_by_projects/0` continues to count all sessions regardless of project archive status.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Missing a `list_projects/0` call site that should still include archived projects | Audited all call sites: `ProjectsLive` (5 locations: mount + `project_saved` callback + 3 PubSub handlers) and `CreateSessionLive` (2 locations). All should exclude archived. No other call sites exist. |
| Route conflict if `/projects/:id` is added later | `/projects/archived` is placed above `/projects` in the router, and above any future parameterized route. |

## Sources & References

- Related code: `lib/destila/workflows.ex` — session archiving reference implementation
- Related code: `lib/destila_web/live/archived_sessions_live.ex` — archived page reference
- Related code: `lib/destila_web/live/projects_live.ex` — project cards and delete confirmation pattern
- Related feature: `features/session_archiving.feature`
- Related plan: `docs/plans/2026-03-24-feat-archive-workflow-sessions-plan.md`
