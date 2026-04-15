---
title: "feat: AI Sessions sidebar and detail page"
type: feat
status: active
date: 2026-04-15
---

# feat: AI Sessions Sidebar and Detail Page

## Overview

Add an "AI Sessions" section to the right metadata sidebar in `WorkflowRunnerLive` and a new `AiSessionLive` detail page. The sidebar section lists each Claude API session belonging to the current workflow session, shows a per-session message count, and links to the detail page. The detail page shows session metadata and all messages in order. The sidebar section updates in real time via the existing `"store:updates"` PubSub topic. The detail page loads once on mount and does not subscribe to real-time updates.

## Problem Frame

The application has no UI surface that exposes the AI sessions associated with a workflow session, even though the `ai_sessions` table and its `messages` are already persisted. Engineers and power users have no way to inspect which Claude API sessions were created for a workflow run, how many messages each produced, or what those messages contained.

## Requirements Trace

- R1. Right sidebar lists all AI sessions for the current workflow session, each showing a message count and linking to the detail page.
- R2. Right sidebar shows an empty state when no AI sessions exist.
- R3. The sidebar list refreshes in real time when AI sessions are created or messages are added.
- R4. A detail page at `/sessions/:id/ai/:ai_session_id` shows the session's creation timestamp, `claude_session_id`, and all messages in chronological order.
- R5. The detail page includes a back button navigating to `/sessions/:id`.
- R6. Gherkin scenarios in `features/ai_sessions.feature` cover all of the above behaviors.

## Scope Boundaries

- No new PubSub subscription is added — only new `handle_info` clauses under the existing `"store:updates"` subscription.
- No right sidebar layout changes; the AI Sessions section is placed inside the existing `metadata-sidebar-content` div.
- No real-time streaming on the `AiSessionLive` detail page; it loads once on mount (not in scope per the feature description).
- The existing `get_ai_session_for_workflow/1` and `get_ai_session_for_workflow!/1` functions are not modified.

## Context & Research

### Relevant Code and Patterns

- **Sidebar structure**: `lib/destila_web/live/workflow_runner_live.ex` — sidebar items use a consistent `<.link>` or `<button>` pattern: icon wrapper span + label span + trailing icon, classed `w-full flex items-center gap-2.5 px-2 py-1.5 rounded-md hover:bg-base-200/60`. The `metadata-sidebar-content` div holds all sections.
- **Sub-resource detail page pattern**: `lib/destila_web/live/terminal_live.ex` — canonical pattern: `live "/sessions/:id/terminal"`, mount fetches workflow session by `:id`, redirects on failure, uses `<Layouts.app flash={@flash} page_title={...}>`, back button as `<.link navigate={~p"/sessions/#{@workflow_session.id}"}>` with `hero-arrow-left-micro` icon.
- **PubSub dispatch**: `lib/destila/pub_sub_helper.ex` — all broadcasts go to `"store:updates"`. `WorkflowRunnerLive` already subscribes on connect; its `handle_info` has a catch-all `_msg -> {:noreply, socket}` that silently drops unknown messages.
- **AI context**: `lib/destila/ai.ex` — `get_ai_session_for_workflow/1` queries the single latest session (`limit: 1`). `create_message/2` inserts and broadcasts `:message_added` on `"store:updates"`. `list_messages_for_workflow_session/1` fetches messages ordered by `inserted_at`.
- **Schemas**: `lib/destila/ai/session.ex` — `:id` (binary_id), `:claude_session_id`, `:worktree_path`, `:workflow_session_id`, `has_many :messages`, `:inserted_at`/`:updated_at`. `lib/destila/ai/message.ex` — `:id`, `:role` (enum), `:content`, `:raw_response`, `:ai_session_id`, `:workflow_session_id`, `:inserted_at` (usec, no updated_at).
- **Router scope**: `lib/destila_web/router.ex` — single `scope "/", DestilaWeb do … pipe_through :browser`. New route must precede `live "/sessions/:id", WorkflowRunnerLive`.
- **LiveView streams**: CLAUDE.md mandates streams for growing collections; messages on the detail page qualify.
- **Layouts**: `lib/destila_web/components/layouts.ex` — every LiveView wraps content in `<Layouts.app flash={@flash} page_title={@page_title}>`. `Layouts` is aliased globally in `destila_web.ex`.

### Institutional Learnings

No `docs/solutions/` knowledge base exists yet. All patterns are derived from existing modules.

## Key Technical Decisions

- **Aggregate query returns plain maps, not `Session` structs**: `list_ai_sessions_for_workflow/1` uses a `select` that returns `%{id, inserted_at, claude_session_id, message_count}`. Adding a virtual field to the `Session` schema just for this query would be an unnecessary schema change; a plain map is sufficient and safe to pattern-match in the template.
- **Broadcast on both `create_ai_session/1` and `get_or_create_ai_session/2`**: Both functions call `Repo.insert()` independently; both must pipe through `|> PubSubHelper.broadcast(:ai_session_created)` — the same pattern used by `create_message/2`. `get_or_create_ai_session/2` is the primary session creation path (called from `conversation.ex` via `ensure_ai_session/1`); omitting the broadcast there would leave R3 mostly unfulfilled.
- **WorkflowRunnerLive refreshes `:ai_sessions` on two events with session-ID guards**: `{:ai_session_created, ai_session}` (guards on `ai_session.workflow_session_id`) and `{:message_added, message}` (guards on `message.workflow_session_id`). Both already land on `"store:updates"`. Guards are mandatory — the topic is global and unguarded clauses would re-query on events from every other workflow session. No new subscription is added.
- **`AiSessionLive` does not subscribe to real-time updates**: The feature description does not require live updates on the detail page. Subscribing would add complexity without a stated need; this is deferred to implementation discovery.
- **New context helpers for the detail page**: `get_ai_session!/1` (fetch by id) and `list_messages_for_ai_session/1` (fetch messages by `ai_session_id`) are added to `Destila.AI` as minimal helpers, consistent with the existing read-function naming convention.
- **Route param naming**: The workflow session param stays `:id` (consistent with `TerminalLive`); the AI session param is `:ai_session_id`. This avoids any ambiguity in `mount` pattern matching.

## Open Questions

### Resolved During Planning

- **Where in the sidebar does the AI Sessions section go?** After the existing Exported Metadata section; separated by the same divider pattern used between Workflow Session and Exported Metadata sections.
- **What format does `create_message/2` use for its broadcast?** It broadcasts `{:message_added, message}` via `PubSubHelper` to `"store:updates"`. WorkflowRunnerLive will add a matching clause.
- **How is the route nested without a `live_session` block?** All routes are plain `live` calls — no `live_session` wrapper — following the no-auth pattern established for the whole app.

### Deferred to Implementation

- **Does `create_ai_session/1` currently call `PubSubHelper` at all?** The research shows it doesn't; the implementing agent must verify and add the broadcast call.
- **Exact `PubSubHelper` call signature for `broadcast_event`**: Verify arity and expected arguments by reading `pub_sub_helper.ex` during implementation.
- **Whether `{:message_added, msg}` already hits WorkflowRunnerLive's handle_info catch-all**: Confirm by tracing `create_message/2` to its broadcast path.

## Implementation Units

```
Unit 1: AI context additions
    │
    ├── Unit 2: WorkflowRunnerLive assigns + handle_info
    │       │
    │       └── Unit 3: Right sidebar template section
    │
    ├── Unit 4: Router route
    │
    └── Unit 5: AiSessionLive module
            │
            └── Unit 6: Gherkin feature file
```

---

- [ ] **Unit 1: AI context additions**

**Goal:** Add query and helper functions to `Destila.AI` that support both the sidebar (aggregate list) and the detail page (single session fetch + messages by AI session).

**Requirements:** R1, R3, R4

**Dependencies:** None

**Files:**
- Modify: `lib/destila/ai.ex`
- Test: `test/destila/ai_test.exs`

**Approach:**
- `list_ai_sessions_for_workflow(workflow_session_id)` — Ecto query joining `Session` left-joining `Message` on `m.ai_session_id == s.id`, grouped by `[s.id, s.inserted_at, s.claude_session_id]` (all non-aggregate selected fields), ordered `asc: s.inserted_at`, limited to the most recent 50 sessions, selecting a plain map: `%{id: s.id, inserted_at: s.inserted_at, claude_session_id: s.claude_session_id, message_count: count(m.id)}`. Returns an empty list when the workflow session has no AI sessions. The `count(m.id)` aggregate on a LEFT JOIN returns `0` for sessions with no messages in SQLite/Ecto; add `fragment("COALESCE(?, 0)", count(m.id))` if zero-message sessions are not returning `0` in tests.
- `get_ai_session/1` — `Repo.get(Session, id)`, returns nil when not found. Used by `AiSessionLive` mount (nil-check pattern, not bang + rescue).
- `get_ai_session!/1` — `Repo.get!(Session, id)`. Available for use cases where not-found is a programming error.
- `list_messages_for_ai_session/1` — queries `Message` where `ai_session_id == ^id`, ordered by `asc: :inserted_at`. Used by `AiSessionLive` mount.
- Broadcast addition in `create_ai_session/1` and `get_or_create_ai_session/2` — pipe `Repo.insert()` through `|> PubSubHelper.broadcast(:ai_session_created)`, identical to how `create_message/2` pipes `|> broadcast(:message_added)`. `PubSubHelper.broadcast/2` takes `{:ok, entity}` or `{:error, _}`, broadcasts only on success as `{:ai_session_created, ai_session}`, and returns `{:ok, ai_session}` — preserving the function's return value. Do **not** use `PubSubHelper.broadcast_event/2` (its call signature is `(event, data)` and would produce a wire message of `{event_tuple, data}`, not matching the `handle_info` pattern). `get_or_create_ai_session/2` has its own `Repo.insert()` call that does not delegate to `create_ai_session/1`; both paths must broadcast.

**Patterns to follow:**
- `get_ai_session_for_workflow/1` — query structure
- `list_messages_for_workflow_session/1` — message query structure and ordering
- `create_message/2` — insert + broadcast pattern

**Test scenarios:**
- Happy path: `list_ai_sessions_for_workflow/1` with two AI sessions (one with 3 messages, one with 0) returns both entries with correct `message_count` values, ordered by `inserted_at` ascending.
- Edge case: `list_ai_sessions_for_workflow/1` with no AI sessions returns `[]`.
- Happy path: `get_ai_session!/1` returns the correct struct for a known id.
- Error path: `get_ai_session!/1` raises `Ecto.NoResultsError` for an unknown id.
- Happy path: `list_messages_for_ai_session/1` returns messages in `inserted_at` ascending order for a known AI session.
- Edge case: `list_messages_for_ai_session/1` returns `[]` for an AI session with no messages.
- Integration: `create_ai_session/1` broadcasts `{:ai_session_created, ai_session}` on `"store:updates"` after a successful insert (subscribe in test, assert_receive).

**Verification:**
- All new functions pass their tests with `mix test test/destila/ai_test.exs`.

---

- [ ] **Unit 2: WorkflowRunnerLive — ai_sessions assign and handle_info clauses**

**Goal:** Assign `:ai_sessions` on mount and keep it fresh via two new `handle_info` clauses, so the sidebar always reflects the current state.

**Requirements:** R1, R2, R3

**Dependencies:** Unit 1

**Files:**
- Modify: `lib/destila_web/live/workflow_runner_live.ex`

**Approach:**
- In `mount_session/2`, after `assign_worktree_path/2`, call `AI.list_ai_sessions_for_workflow(ws_id)` and assign `:ai_sessions`.
- Add two `handle_info` clauses **before** the existing catch-all:
  - `handle_info({:ai_session_created, ai_session}, socket)` — guard on `ai_session.workflow_session_id == socket.assigns.workflow_session.id` before reassigning `:ai_sessions`. This matches the guard pattern of the existing `handle_info({:metadata_updated, ws_id}, socket)` clause.
  - `handle_info({:message_added, message}, socket)` — guard on `message.workflow_session_id == socket.assigns.workflow_session.id` before reassigning `:ai_sessions` (refreshes per-session message counts). Without this guard, every WorkflowRunnerLive instance would re-query on every message from any session — `"store:updates"` is a single global topic.
- Both clauses extract `ws_id` from `socket.assigns.workflow_session.id` for the re-query call.

**Patterns to follow:**
- Existing `assign_worktree_path/2` call in `mount_session/2` for the mount side.
- Existing `handle_info({:metadata_updated, _ws_id}, socket)` — close analogue for the handle_info side (reassigns computed values from the DB).

**Test scenarios:**
- These behaviors are verified via the sidebar LiveView test in Unit 3.

**Verification:**
- `mix test test/destila_web/live/workflow_runner_live/` passes with no new failures.
- Dialyzer / compiler emits no warnings for the new clauses.

---

- [ ] **Unit 3: Right sidebar — AI Sessions section**

**Goal:** Render an "AI Sessions" section inside the existing `metadata-sidebar-content` div, with per-session link items and an empty state.

**Requirements:** R1, R2

**Dependencies:** Unit 2

**Files:**
- Modify: `lib/destila_web/live/workflow_runner_live.ex` (template portion)
- Test: `test/destila_web/live/workflow_runner_live/ai_sessions_sidebar_test.exs`

**Approach:**
- Add a divider followed by an "AI Sessions" section heading after the Exported Metadata section inside `id="metadata-sidebar-content"`.
- When `@ai_sessions == []`, render a single row with muted "No AI sessions yet" text inside `id="ai-sessions-empty-state"`.
- Otherwise render a `<%= for session <- @ai_sessions do %>` loop. Each item:
  - `<.link navigate={~p"/sessions/#{@workflow_session.id}/ai/#{session.id}"}` with a unique `id={"ai-session-item-#{session.id}"}`.
  - Icon: `hero-cpu-chip-micro` (or similar) in a `size-5` span.
  - Label: `"AI Session"` or a short date string in the label span.
  - Trailing count badge: `session.message_count` messages count.
- The section container gets `id="ai-sessions-section"` for test targeting.
- Use the `[...]` class list syntax for conditional classes per CLAUDE.md.
- Do **not** use `phx-update="stream"` on this list. CLAUDE.md's stream mandate applies to unbounded growing collections appended incrementally. The AI sessions list is refreshed wholesale via a regular assign on each event (not incrementally appended), and is bounded by a `LIMIT` clause in `list_ai_sessions_for_workflow/1` (see Unit 1 approach). Streams are not applicable here.

**Patterns to follow:**
- Terminal link item in the sidebar (lines ~820–840 in `workflow_runner_live.ex`).
- Exported Metadata section structure for heading + loop.

**Test scenarios:**
- Happy path: Given a workflow session with two AI sessions (with message counts), the LiveView renders `#ai-sessions-section` and two `[id^="ai-session-item-"]` link elements.
- Happy path: Each rendered item contains the correct message count (assert text or element presence with count label).
- Happy path: Each item's `navigate` href is `/sessions/:ws_id/ai/:ai_session_id`.
- Edge case: With no AI sessions, `#ai-sessions-empty-state` is present and `[id^="ai-session-item-"]` elements are absent.
- Integration: When a new AI session is created (simulated via `Phoenix.PubSub.broadcast/3` to `"store:updates"` with `{:ai_session_created, ai_session}` where `ai_session.workflow_session_id` matches), the sidebar list updates to include the new item after `render/1`.
- Integration: When a message is added (simulated via `Phoenix.PubSub.broadcast/3` with `{:message_added, message}` where `message.workflow_session_id` matches), the message count for the relevant AI session item updates in the sidebar.
- Edge case: When `{:message_added, message}` arrives for a different `workflow_session_id`, the sidebar does not re-render or re-query (verify via a count assert on the initial DOM state being unchanged).

**Verification:**
- `mix test test/destila_web/live/workflow_runner_live/ai_sessions_sidebar_test.exs` passes.

---

- [ ] **Unit 4: Router route**

**Goal:** Register the new `/sessions/:id/ai/:ai_session_id` route in the router.

**Requirements:** R4, R5 (navigation target must be reachable)

**Dependencies:** Unit 5 (module `DestilaWeb.AiSessionLive` must exist for the route to compile — implement Unit 5 first)

**Files:**
- Modify: `lib/destila_web/router.ex`

**Approach:**
- Inside the existing `scope "/", DestilaWeb do` block, add `live "/sessions/:id/ai/:ai_session_id", AiSessionLive` after `live "/sessions/:id/terminal", TerminalLive`, following the same placement pattern. Phoenix resolves routes by path segment count — a four-segment path cannot shadow a two-segment route, so ordering relative to `live "/sessions/:id", WorkflowRunnerLive` does not matter.
- No `live_session` wrapper needed (consistent with all other routes in the app).

**Patterns to follow:**
- `live "/sessions/:id/terminal", TerminalLive` — placed after `WorkflowRunnerLive` in the current router; the new route follows the same pattern.

**Test scenarios:**
- Test expectation: none — route registration is validated by compilation and by the LiveView tests that navigate to this path.

**Verification:**
- `mix compile` succeeds.
- `mix phx.routes` output contains the new route pointing to `AiSessionLive`.

---

- [ ] **Unit 5: AiSessionLive module**

**Goal:** Create the detail page LiveView at `/sessions/:id/ai/:ai_session_id`, displaying session metadata and all messages.

**Requirements:** R4, R5

**Dependencies:** Unit 1 (context helpers must exist for mount to compile)

**Files:**
- Create: `lib/destila_web/live/ai_session_live.ex`
- Test: `test/destila_web/live/ai_session_live_test.exs`

**Approach:**
- Module name: `DestilaWeb.AiSessionLive`.
- `mount/3`: receive `%{"id" => ws_id, "ai_session_id" => ai_session_id}`.
  - `Workflows.get_workflow_session(ws_id)` — on nil, redirect to `/` with a flash error. Mirrors `TerminalLive`'s nil-check pattern — never use a bang + rescue in mount.
  - `AI.get_ai_session(ai_session_id)` (add a nil-returning `Repo.get(Session, id)` helper alongside `get_ai_session!/1`) — on nil, redirect to `/sessions/#{ws_id}` with a flash error. Use the nil-returning variant, not `get_ai_session!/1` + rescue — the existing codebase never uses try/rescue in mount callbacks.
  - Cross-validate ownership: after both fetches, verify `ai_session.workflow_session_id == workflow_session.id`. If not, redirect to `/sessions/#{ws_id}` with a flash error. This prevents loading an AI session belonging to a different workflow session via a crafted URL.
  - `AI.list_messages_for_ai_session(ai_session_id)` — stream into `:messages` via `stream(socket, :messages, messages)`.
  - Assign `:workflow_session`, `:ai_session`, `page_title: "AI Session — #{ws.title}"`.
- Template:
  - `<Layouts.app flash={@flash} page_title={@page_title}>` as outer wrapper.
  - Back button: `<.link navigate={~p"/sessions/#{@workflow_session.id}"}` with `hero-arrow-left-micro` icon and "Back" label.
  - Metadata block: display `@ai_session.inserted_at` (formatted) and `@ai_session.claude_session_id` with `id="ai-session-created-at"` and `id="ai-session-claude-id"` respectively.
  - Messages stream: `<div id="ai-session-messages" phx-update="stream"><div :for={{id, msg} <- @streams.messages} id={id}>…</div></div>`. Display `msg.role`, `msg.content` per item.
- No PubSub subscription on this page (out of scope).

**Patterns to follow:**
- `lib/destila_web/live/terminal_live.ex` — mount structure, redirect-on-failure, `<Layouts.app>` wrapper, back button.
- LiveView stream pattern from CLAUDE.md and existing `WorkflowRunnerLive` message stream.

**Test scenarios:**
- Happy path: Mounting with a valid `ws_id` and `ai_session_id` renders `#ai-session-created-at` and `#ai-session-claude-id` with the expected values.
- Happy path: A session with three messages renders three items inside `#ai-session-messages`.
- Happy path: Messages appear in `inserted_at` ascending order.
- Edge case: A session with zero messages renders `#ai-session-messages` with no child items.
- Happy path: A back link (`<a>`) is present pointing to `/sessions/:ws_id`.
- Error path: Mounting with an unknown `ws_id` redirects away (assert redirect response or flash).
- Error path: Mounting with a valid `ws_id` but unknown `ai_session_id` redirects to `/sessions/:ws_id`.
- Error path: Mounting with a valid `ws_id` and a valid `ai_session_id` that belongs to a different workflow session redirects to `/sessions/:ws_id` with a flash error (cross-session ownership check).

**Verification:**
- `mix test test/destila_web/live/ai_session_live_test.exs` passes.

---

- [ ] **Unit 6: Gherkin feature file**

**Goal:** Document the AI sessions feature as Gherkin scenarios in `features/ai_sessions.feature` and link all new tests to scenarios via `@tag` annotations.

**Requirements:** R6 and all scenarios provided in the feature description.

**Dependencies:** Units 3 and 5 (tests reference the scenarios)

**Files:**
- Create: `features/ai_sessions.feature`
- Modify: `test/destila_web/live/workflow_runner_live/ai_sessions_sidebar_test.exs` — add `@moduledoc` and `@tag feature:, scenario:` annotations.
- Modify: `test/destila_web/live/ai_session_live_test.exs` — add `@moduledoc` and `@tag` annotations.

**Approach:**
- Copy the five Gherkin scenarios from the feature description verbatim into the `.feature` file.
- Add `@moduledoc` to each test module referencing the feature file path.
- Tag each test with `@tag feature: "ai_sessions", scenario: "..."` matching the scenario title.

**Patterns to follow:**
- Existing `.feature` files in `features/` and `@tag feature:` usage in test files.

**Test scenarios:**
- Test expectation: none — this unit creates documentation and annotations, not new behavior.

**Verification:**
- `mix test --only feature:ai_sessions` runs without "no tests ran" or tag-resolution warnings.
- All five Gherkin scenarios are covered by at least one tagged test.

---

## System-Wide Impact

- **Interaction graph:** `create_ai_session/1` gains a PubSub broadcast; every subscriber of `"store:updates"` (currently `WorkflowRunnerLive` and any other LiveView that subscribes) will receive `{:ai_session_created, ai_session}`. Existing catch-all clauses handle this safely in views that don't declare a matching clause.
- **Error propagation:** `AiSessionLive` mount uses `get_ai_session/1` (nil-returning), then cross-validates `ai_session.workflow_session_id == workflow_session.id`. Any nil or mismatched id redirects with a flash — this mirrors `TerminalLive`'s nil-check guard pattern and prevents cross-session resource loading via crafted URLs.
- **State lifecycle risks:** The `:ai_sessions` assign holds a list of plain maps, not live structs. Any update to an existing AI session (e.g., `claude_session_id` populated later) will not auto-refresh the sidebar; only creation and message-addition events trigger a refresh. This is acceptable for the initial feature scope.
- **API surface parity:** No new HTTP or REST endpoints. The new LiveView uses `live_path` helpers (`~p"/sessions/:id/ai/:ai_session_id"`) that are validated at compile time.
- **Integration coverage:** The real-time sidebar refresh path (`create_ai_session/1` → PubSub broadcast → `handle_info` in WorkflowRunnerLive → re-assign `:ai_sessions`) crosses context, PubSub, and LiveView layers. The Unit 3 integration test must exercise this full path.
- **Unchanged invariants:** The existing `get_ai_session_for_workflow/1` / `get_ai_session_for_workflow!/1` functions are untouched. `WorkflowRunnerLive`'s `:claude_session_id` and `:worktree_path` assigns continue to be set via `assign_worktree_path/2` and are independent of the new `:ai_sessions` assign.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `create_ai_session/1` is called in hot paths or during setup; adding a broadcast may introduce latency | Broadcast is async via `Phoenix.PubSub.broadcast/3` — non-blocking and sub-millisecond in practice. Accept. |
| SQLite `GROUP BY` + `LEFT JOIN` for message counts may return unexpected results if the query is malformed | Use `group_by: [s.id, s.inserted_at, s.claude_session_id]` to be explicit. Cover with test cases including zero-message sessions; validate against real data in dev before merging. |
| `get_or_create_ai_session/2` is the primary session creation path (conversation.ex) but does not go through `create_ai_session/1` — the broadcast must be added to both | Add the `|> PubSubHelper.broadcast(:ai_session_created)` pipe to both `create_ai_session/1` and the insert branch of `get_or_create_ai_session/2`, or extract a shared private insert helper. |
| Template loop over `:ai_sessions` (plain maps) breaks if the map shape changes in future | The map shape is defined and consumed entirely within this feature's code. Any future change to the query is co-located with the template use. |

## Sources & References

- Related code: `lib/destila_web/live/terminal_live.ex` (detail page pattern)
- Related code: `lib/destila_web/live/workflow_runner_live.ex` (sidebar and PubSub handling)
- Related code: `lib/destila/ai.ex` (context functions)
- Related code: `lib/destila/ai/session.ex`, `lib/destila/ai/message.ex` (schemas)
- Related code: `lib/destila/pub_sub_helper.ex` (broadcast conventions)
- Related code: `lib/destila_web/router.ex` (route placement)
