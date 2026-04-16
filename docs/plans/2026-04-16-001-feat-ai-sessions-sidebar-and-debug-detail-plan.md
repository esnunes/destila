---
title: Add AI Sessions List to Workflow Runner Right Sidebar + AI Session Debug Detail Page
type: feat
status: active
date: 2026-04-16
deepened: 2026-04-16
---

# Add AI Sessions List to Workflow Runner Right Sidebar + AI Session Debug Detail Page

## Overview

Add two debugging-oriented features to the Destila workflow runner:

1. An **"AI Sessions" section** in the workflow runner right sidebar that lists every AI session belonging to the current workflow session. Each row shows the creation date and a live aliveness dot (green when the Claude Code GenServer is running, muted/gray when not). Clicking a row navigates to a new detail page.

2. A new **AI Session Debug Detail page** at `/sessions/:workflow_session_id/ai/:ai_session_id`. This page is designed for debugging what happened inside a specific AI session: it shows the session's creation date and `claude_session_id` in a header, then renders the full conversation history read exclusively via `ClaudeCode.History.get_messages/2` (the string-keyed variant — see "Verified History API" in Key Technical Decisions), rendering every content block type (text, thinking, tool calls, tool results, server tool usage, MCP tool usage, images, documents, redacted thinking, container uploads, compaction markers).

## Problem Frame

Today, the only way to inspect a past AI session's raw conversation is to open a terminal and `cat` the JSONL file under `~/.claude/projects/...`. There is also no visible list of historical AI sessions for a workflow — the sidebar shows workflow metadata but never the AI sessions themselves, and the workflow-level aliveness dot in the header tells you only whether *something* is running, not which AI session. This plan surfaces both: a sidebar index of all AI sessions for the workflow with per-session aliveness, and a dedicated page for reading the full conversation history of a specific AI session.

## Requirements Trace

- **R1.** Render an "AI Sessions" section in the `WorkflowRunnerLive` right sidebar, between the existing "Workflow Session" section and the "Exported Metadata" section.
- **R2.** Each sidebar item shows the creation date and an aliveness dot that live-updates (green = alive, muted/gray = not running), and navigates to the detail page on click.
- **R3.** Show an empty state in the sidebar when the workflow has no AI sessions.
- **R4.** Add route `live "/sessions/:workflow_session_id/ai/:ai_session_id", AiSessionDetailLive` inside the existing `scope "/", DestilaWeb` block.
- **R5.** The detail page header displays the session's creation date and `claude_session_id`.
- **R6.** The detail page renders the full conversation history exclusively via `ClaudeCode.History.get_messages(claude_session_id, opts \\ [])` (the string-session-id variant; `ClaudeCode.Session.get_messages/2` takes a live session PID and is **not** what we want here).
- **R7.** The renderer handles every content block struct type listed in the prompt (`TextBlock`, `ThinkingBlock`, `RedactedThinkingBlock`, `ToolUseBlock`, `ToolResultBlock`, `ServerToolUseBlock`, `ServerToolResultBlock`, `MCPToolUseBlock`, `MCPToolResultBlock`, `ImageBlock`, `DocumentBlock`, `ContainerUploadBlock`, `CompactionBlock`).
- **R8.** Tool calls are visually paired with their matching tool results via `tool_use_id`.
- **R9.** Thinking blocks render collapsed by default and can be expanded.
- **R10.** Tool input/output render as pretty JSON; tool-result blocks render with an error style when `:is_error` is `true`.
- **R11.** Unknown/future content block types use a generic fallback (e.g. `inspect/2`) and never crash the page.
- **R12.** The detail page renders an empty state when `claude_session_id` is nil or `History.get_messages/2` returns `{:error, _}` or `{:ok, []}`.
- **R13.** Extending the aliveness tracker must not break the existing `workflow_session_id`-based aliveness used by the Crafting Board and the workflow runner header.
- **R14.** The new sidebar section must render correctly whether the sidebar is expanded or collapsed (it lives inside `#metadata-sidebar-content`, which is hidden as a unit).
- **R15.** Every Gherkin scenario in `features/ai_session_sidebar.feature` and `features/ai_session_detail.feature` has at least one linked LiveView test via `@tag feature:/scenario:`.

## Scope Boundaries

- Not building an editing/rerun UI for past AI sessions. Detail page is read-only.
- Not changing how AI sessions are created or associated with Claude Code processes.
- Not persisting conversation history to our DB — reads stay on-disk via `ClaudeCode.History.get_messages/2`.
- Not adding pagination for large histories in the MVP. `ClaudeCode.History.get_messages/2` accepts `limit:`/`offset:` opts and can be wired up later.
- Not adding the ability to resume/clone a past session from the detail page.
- Not redesigning the existing header aliveness dot in `WorkflowRunnerLive` — it keeps its current per-workflow semantics.

## Context & Research

### Relevant Code and Patterns

- **`lib/destila/ai/aliveness_tracker.ex`** — GenServer + ETS that currently tracks aliveness by `workflow_session_id` (Registry key). On `{:claude_session_started, workflow_session_id}` from `PubSubHelper.claude_session_topic()`, it monitors the pid and broadcasts `{:aliveness_changed, workflow_session_id, alive?}` on topic `"session_aliveness"`.
- **`lib/destila/ai.ex`** — `get_ai_session_for_workflow/1` (returns the latest AI session, `order_by: [desc: :inserted_at], limit: 1`) is the canonical pattern to mirror when adding `list_ai_sessions_for_workflow/1` (same query, no `limit`).
- **`lib/destila/ai/session.ex`** — AI session schema with `claude_session_id`, `worktree_path`, `workflow_session_id`, `inserted_at`. Primary key is `binary_id`.
- **`lib/destila/ai/claude_session.ex`** — Wrapper around `ClaudeCode.start_link`. On init (line 192–198) it broadcasts `{:claude_session_started, workflow_session_id}` to `PubSubHelper.claude_session_topic()`. `workflow_session_id` is already in state; `ai_session_id` is not currently passed in.
- **`lib/destila/ai/conversation.ex:117`** — `AI.update_ai_session(ai_session, %{claude_session_id: result[:session_id]})` is where the AI session record captures its `claude_session_id` after the first stream completes. This is the only place where the ai_session ↔ claude_session_id link is established.
- **`lib/destila/workers/ai_query_worker.ex:25`** — **Verified call site for `ClaudeSession.for_workflow_session/2`.** The worker calls `AI.SessionConfig.session_opts_for_workflow(ws, phase)` to build the opts keyword list, then passes those opts through unchanged to `AI.ClaudeSession.for_workflow_session(workflow_session_id, session_opts)`. There is no direct `ClaudeSession.for_workflow_session/2` call in `Conversation.ex` — `Conversation.phase_start/*` calls `AI.get_or_create_ai_session/2` and enqueues the Oban worker, which in turn starts the ClaudeSession. **This is where `ai_session_id` must be injected.**
- **`lib/destila/ai/session_config.ex:17-55`** — **Verified insertion point for `ai_session_id` opt.** `session_opts_for_workflow/3` already fetches `ai_session = Destila.AI.get_ai_session_for_workflow(workflow_session.id)` (line 26) and uses it to populate `:resume` (from `ai_session.claude_session_id`) and `:cwd` (from `ai_session.worktree_path`). The natural seam is one more `Keyword.put(opts, :ai_session_id, ai_session.id)` in the same block, guarded by the existing `ai_session != nil` branch. No change needed in `AiQueryWorker` — it forwards the full opts keyword list.
- **`lib/destila_web/live/workflow_runner_live.ex`** — Right sidebar lives at lines 695–900+. Key anchor points: `<div id="user-prompt-section">` at ~line 724 (header "Workflow Session"), divider at ~line 863, Exported Metadata section at ~line 866 (header "Exported Metadata"). Mount already subscribes to `AlivenessTracker.topic()` and handles `{:aliveness_changed, ws_id, alive?}` at ~line 468. The `.MetadataSidebar` colocated JS hook at line 1079+ toggles the whole `#metadata-sidebar-content` div visibility — the new section nests inside this div and needs no extra hook logic.
- **`lib/destila_web/components/board_components.ex:42`** — `aliveness_dot/1` is the existing visual primitive: green `bg-success`, muted `bg-base-content/20`, red pulsing `bg-error animate-pulse`. Reuse by passing `phase_status` explicitly so the muted-vs-red branching still works for historical sessions without a live workflow phase.
- **`lib/destila_web/live/terminal_live.ex`** — Single-purpose detail LiveView pattern to mirror: mount validates by looking up the workflow session, redirects with `put_flash` on missing, renders a `Layouts.app` header with a back-link icon (`hero-arrow-left-micro`) pointing to `~p"/sessions/#{ws.id}"`, and uses `page_title` like `"Terminal — #{ws.title}"`.
- **`lib/destila_web/router.ex`** — Add the new route inside `scope "/", DestilaWeb` below the existing `/sessions/:id` routes. No `live_session` wrapper is used.
- **`lib/destila/pub_sub_helper.ex`** — Provides `claude_session_topic/0` (used by both the AlivenessTracker and ClaudeSession). Extending it with a second tuple shape (`:claude_session_started, workflow_session_id, ai_session_id`) keeps the topic stable.
- **`lib/destila_web/components/chat_components.ex`** — Already imports a Markdown rendering function (`markdown_viewer/1`) used for assistant text. The detail page should not try to reuse the full `chat_message/1` — it is overloaded with our own `%Destila.AI.Message{}` schema, not the `ClaudeCode.History.SessionMessage` struct we are rendering here. Keep the renderer separate.
- **`test/destila_web/live/open_terminal_live_test.exs`** — Minimal pattern for a detail-page LiveView test; also shows how `ClaudeCode.Test.set_mode_to_shared/0` + `ClaudeCode.Test.stub/2` is used in tests. The `ClaudeCode.Test` helpers do not obviously cover `Session.get_messages/1`, so we add a thin adapter (see Unit 5) to make the call swappable in tests.

### Institutional Learnings

No matching entries found in `docs/solutions/` for this specific work. The closest adjacent patterns are the existing terminal-detail LiveView and the aliveness infrastructure added for the Crafting Board, both already in-tree.

### External References

- **Verified in `deps/claude_code/` (installed).** Two distinct `get_messages` functions exist in the installed version:
  - `ClaudeCode.History.get_messages(session_id, opts \\ [])` — `@spec get_messages(session_id(), keyword()) :: {:ok, [SessionMessage.t()]} | {:error, term()}` (`deps/claude_code/lib/claude_code/history.ex:124`). **This is the one we want** — it takes the `claude_session_id` string and reads the JSONL file directly.
  - `ClaudeCode.Session.get_messages(session, opts \\ [])` — `@spec get_messages(session(), keyword()) :: ...` (`deps/claude_code/lib/claude_code/session.ex:351`). Takes a **live session PID** and calls `GenServer.call(session, {:history_call, :get_messages, opts})`. Not applicable here — the detail page reads *past* sessions whose PIDs are gone.
- `ClaudeCode.History.SessionMessage` struct fields (verified at `deps/claude_code/lib/claude_code/history/session_message.ex`): `:type` (`:user | :assistant`), `:uuid`, `:session_id`, `:message`, `:parent_tool_use_id`. For `:user` type, `:message` is a plain map `%{content: parsed_content, role: :user}`. For `:assistant`, `:message` is a parsed `%ClaudeCode.Message.AssistantMessage{}` when parsing succeeds, else a normalized raw map (fallback is built into `parse_inner_message/3`, so we inherit the tolerance for free).
- Content block structs live under `ClaudeCode.Content.*` — see `deps/claude_code/lib/claude_code/content/` (already installed locally) and https://github.com/guess/claude_code/tree/main/lib/claude_code/content/ for the canonical field names used below.

## Key Technical Decisions

- **Extend `AlivenessTracker` to store both keys, not replace the workflow_session_id key.** The existing header aliveness dot, the Crafting Board cards, and the WorkflowRunnerLive header already depend on `alive?(workflow_session_id)` and `{:aliveness_changed, workflow_session_id, alive?}`. We keep that contract, and add parallel storage/broadcast keyed by `ai_session_id`. The ETS table can either grow into a tagged key (`{:workflow, ws_id}` / `{:ai, ai_id}`) or we can split into two tables — we go with tagged keys in a single table to preserve atomic lookup patterns.
- **Plumb `ai_session_id` through `ClaudeSession` init, not through a DB lookup inside the tracker.** The caller (`Destila.AI.Conversation`) already knows which ai_session is about to own this ClaudeSession; passing it through opts avoids a DB query in the hot path and a race where the ai_session row exists but has no `claude_session_id` yet. The broadcast message becomes `{:claude_session_started, workflow_session_id, ai_session_id}` (a 3-tuple), and the `AlivenessTracker` handles both the old 2-tuple and the new 3-tuple for compatibility during rollout. The tracker broadcasts two separate `{:aliveness_changed, ...}` messages — one for the workflow key, one for the ai key — so existing subscribers need no change.
- **Verified History API.** Use `ClaudeCode.History.get_messages/2` (takes the `claude_session_id` string). The Session-module variant (`ClaudeCode.Session.get_messages/2`) takes a live GenServer PID and is the wrong surface — by the time the detail page loads, the originating ClaudeSession GenServer is usually gone. Confirmed by reading `deps/claude_code/lib/claude_code/history.ex` and `deps/claude_code/lib/claude_code/session.ex`.
- **Introduce a thin `Destila.AI.History` adapter module** that delegates to `ClaudeCode.History.get_messages/2`. The LiveView calls `Destila.AI.History.get_messages/1` (or `/2`); tests override the delegate target via `Application.put_env(:destila, :ai_history_module, ...)` to return fixture messages. This avoids trying to stub a function we do not own and keeps `ClaudeCode.Test.stub` usage focused on live streaming.
- **Render `SessionMessage`s with a dedicated function component module `DestilaWeb.AiSessionDebugComponents`**, not by reusing `ChatComponents`. The chat components expect our `%Destila.AI.Message{}` schema with `role`/`content`/`raw_response`; the history structs are a different shape (`%ClaudeCode.History.SessionMessage{}` wrapping `%ClaudeCode.Content.*{}` blocks). Mixing them would pollute chat components with debug-only branches.
- **Build a `%{tool_use_id => tool_use_block}` index up-front** by walking all messages once before rendering, then use the index to find the originating tool-use struct when rendering a `ToolResultBlock`/`ServerToolResultBlock`/`MCPToolResultBlock`. This is cheaper than re-scanning the list for every result block and produces stable visual pairing even when the tool_use and tool_result span different messages.
- **Fallback on `inspect/2` for unrecognized content blocks.** Future claude_code releases will add new block types; a catch-all `_ -> inspect(block, pretty: true, limit: :infinity)` inside a `<pre>` renders the raw struct without crashing the LiveView.
- **Tolerate parser fallbacks.** `:message` may be a parsed struct map *or* a raw fallback map when the JSONL row failed to parse. The renderer treats `message` as an opaque map, using `Map.get/2` with both atom and string keys as needed, and wraps the content iteration so a non-list `:content` degrades to a single raw-map fallback rather than a crash.
- **Empty-state triggers.** The detail page short-circuits to an empty state for any of: `ai_session.claude_session_id == nil`, `{:ok, []}`, or `{:error, _}` from `History.get_messages/1`. Logging happens at `Logger.warning` for `{:error, _}` only.

## Open Questions

### Resolved During Planning

- **Does the tracker need to track ai_session_id independently of workflow_session_id, given there's only one ClaudeSession per workflow_session at a time?** Resolved: yes, because the user-facing surface is a list of historical AI sessions, and we want the *currently-bound* AI session to show green while older ones show muted. Binding `ai_session_id` at ClaudeSession init gives us that per-session granularity without changing the Registry key.
- **Where to pass `ai_session_id` into `ClaudeSession`?** Resolved via opts in `init/1`, mirroring how `workflow_session_id` is already plumbed.
- **How to test `ClaudeCode.History.get_messages/2` without touching the real `~/.claude/projects` tree?** Resolved via a `Destila.AI.History` adapter configured through `Application.get_env`, defaulting to the real `ClaudeCode.History`. See Unit 5.
- **Reuse `ChatComponents` for rendering?** Resolved: no — different input struct shape. See Key Technical Decisions.
- **Route shape.** Resolved: `/sessions/:workflow_session_id/ai/:ai_session_id` maps to `DestilaWeb.AiSessionDetailLive` inside the existing `scope "/", DestilaWeb`.

### Deferred to Implementation

- **Exact Tailwind classes for the AI Sessions sidebar rows.** Visual style to match existing `user-prompt-section` buttons: `w-full flex items-center gap-2.5 px-2 py-1.5 rounded-md hover:bg-base-200/60`. Exact wording, icon choice (`hero-chat-bubble-oval-left-micro` vs `hero-cpu-chip-micro`), and spacing will be finalized with the visual pass during implementation.
- **Whether to show message count or timestamps alongside each row.** The prompt only requires creation date; we will add counts only if they fit cleanly without clutter.
- **How to escape/render very long JSON blobs in tool inputs/outputs.** Truncation thresholds and CSS `max-h` with a "show full" toggle are decided at implementation time based on how they feel with real data.
- **Accessibility semantics for the collapsible thinking block.** `<details>`/`<summary>` vs button-plus-aria-expanded is decided at implementation time.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

**Aliveness flow (dual-key):**

```
ClaudeSession.init(opts: [workflow_session_id, ai_session_id, ...])
  ├─ starts ClaudeCode
  └─ broadcasts {:claude_session_started, ws_id, ai_id} on "claude_sessions"

AlivenessTracker
  ├─ on init + on :claude_session_started:
  │     monitor(pid)
  │     ets.insert({:workflow, ws_id}, true)    ← preserves existing contract
  │     ets.insert({:ai, ai_id}, true)          ← new
  │     broadcast({:aliveness_changed, ws_id, true})
  │     broadcast({:aliveness_changed_ai, ai_id, true})
  └─ on :DOWN:
        ets.delete({:workflow, ws_id})
        ets.delete({:ai, ai_id})
        broadcast both false

Public API
  ├─ alive?(ws_id)              ← unchanged
  └─ alive_ai?(ai_id)            ← new
```

**Detail-page render pipeline:**

```
mount(%{"workflow_session_id" => ws_id, "ai_session_id" => ai_id})
  ├─ load ai_session, validate ai_session.workflow_session_id == ws_id
  ├─ if claude_session_id is nil → empty state
  ├─ else Destila.AI.History.get_messages(claude_session_id)
  │       { :ok, [] }        → empty state
  │       { :error, _ }      → log + empty state
  │       { :ok, messages }  → {messages, tool_index}
  └─ render(messages, tool_index)

render(messages, tool_index):
  for each %SessionMessage{type, message}:
    branch on type:
      :assistant → iterate message[:content] blocks (see block table)
      :user      → if binary → text bubble
                   if list   → iterate content blocks

  for each content block, branch on struct:
    TextBlock            → markdown bubble
    ThinkingBlock        → <details> collapsible
    RedactedThinkingBlock→ placeholder
    ToolUseBlock         → name + pretty JSON input; mark id in index
    ToolResultBlock      → look up tool_use by tool_use_id; pair visually;
                           is_error → error style
    ServerToolUseBlock/ResultBlock → same shape, labelled "server tool"
    MCPToolUseBlock/ResultBlock    → same shape + server_name
    ImageBlock / DocumentBlock / ContainerUploadBlock → placeholder card
    CompactionBlock      → "--- Conversation compacted ---" marker
    _ (unknown)          → <pre>{inspect(block, pretty: true)}</pre>
```

**Tool-use index build pass (directional pseudo-code):**

```
tool_index =
  Enum.reduce(messages, %{}, fn msg, acc ->
    content = get_in(msg, [:message, :content]) || []
    content
    |> List.wrap()
    |> Enum.reduce(acc, fn
         %ToolUseBlock{id: id} = b, a      -> Map.put(a, id, b)
         %ServerToolUseBlock{id: id} = b, a -> Map.put(a, id, b)
         %MCPToolUseBlock{id: id} = b, a    -> Map.put(a, id, b)
         _, a                               -> a
       end)
  end)
```

## Implementation Units

- [ ] **Unit 1: Extend `AlivenessTracker` to dual-key (`workflow_session_id` + `ai_session_id`)**

**Goal:** Track aliveness by both keys while preserving the existing `workflow_session_id` contract.

**Requirements:** R13, and enables R2.

**Dependencies:** None.

**Files:**
- Modify: `lib/destila/ai/aliveness_tracker.ex`
- Modify: `lib/destila/ai/claude_session.ex` (broadcast 3-tuple; accept `ai_session_id` opt)
- Modify: `lib/destila/ai/session_config.ex` (**verified insertion point** — inject `ai_session_id: ai_session.id` into the opts keyword returned by `session_opts_for_workflow/3`, adjacent to the existing `:resume`/`:cwd` puts on the `ai_session != nil` branch)
- Modify: `lib/destila/pub_sub_helper.ex` (optional: add a helper to form the 3-tuple if we want a named constructor)
- Test: `test/destila/ai/aliveness_tracker_test.exs` (create if missing)

**Not modified (verified via deps read):** `lib/destila/ai/conversation.ex` does *not* call `ClaudeSession.for_workflow_session/2` directly. `lib/destila/workers/ai_query_worker.ex` forwards `session_opts` unchanged to the ClaudeSession starter, so updating `SessionConfig` is sufficient and avoids threading `ai_session_id` through the worker's args.

**Approach:**
- Store ETS entries under tagged keys: `{{:workflow, ws_id}, true}` and `{{:ai, ai_id}, true}`. Update the existing `alive?/1` implementation to continue looking up `{:workflow, ws_id}` so external callers see no change.
- Add `alive_ai?/1` (or `alive_ai_session?/1`) that looks up `{:ai, ai_id}`.
- Track two independent monitor-ref maps or one map keyed by ref with a `{:workflow_and_ai, ws_id, ai_id}` value so that a single `:DOWN` cleans up both keys atomically.
- In `ClaudeSession.init/1`, pop `:ai_session_id` from opts and include it in the `{:claude_session_started, ws_id, ai_id}` broadcast. Keep the old 2-tuple broadcast path alive as a fallback for safety (the tracker handles both) — or remove it cleanly since we control both producer and consumer. Decision: remove the 2-tuple on the producer side since both ends ship together; the tracker retains a `handle_info/2` clause for the 2-tuple with `ai_id: nil` only to avoid breakage from any in-flight messages during deploy.
- In `lib/destila/ai/session_config.ex` `session_opts_for_workflow/3`, on the `ai_session != nil` branch (where `:resume` and `:cwd` are already injected from `ai_session`), add `Keyword.put(opts, :ai_session_id, ai_session.id)`. The `AiQueryWorker` passes the full opts keyword through to `ClaudeSession.for_workflow_session/2` unchanged, so `ClaudeSession.init/1` receives `ai_session_id` for free.
- Scan on `init/1` is extended: `Registry.select` already yields `{ws_id, pid}`; to recover `ai_session_id` after a tracker restart, fall back to a DB lookup via `AI.get_ai_session_for_workflow/1` (best-effort). If no ai_session exists yet, skip the `{:ai, ai_id}` entry — the next claude_session_started broadcast will fill it in.

**Patterns to follow:**
- `lib/destila/ai/aliveness_tracker.ex` existing monitor/broadcast loop (don't change the topic name).

**Test scenarios:**
- Happy path: simulating `{:claude_session_started, ws_id, ai_id}` populates both ETS entries and broadcasts both aliveness messages.
- Happy path: `alive?/1` returns true for ws_id; `alive_ai?/1` returns true for ai_id.
- Edge case: a `:DOWN` for the monitored pid clears both entries and broadcasts both `false` messages.
- Edge case: init scan where a ClaudeSession is already running and an ai_session row exists for that ws_id — both keys are populated.
- Edge case: init scan where a ClaudeSession is running but no ai_session row has been created yet — only `{:workflow, ws_id}` is populated, no crash.
- Integration: starting a real-ish `ClaudeSession` (via the existing stub) triggers both broadcasts end-to-end.

**Verification:**
- Existing `alive?(workflow_session_id)` behavior is unchanged for all prior callers.
- `alive_ai?(ai_session_id)` returns true exactly when a ClaudeSession bound to that ai_session is running.
- Both PubSub messages are emitted on start and on stop.

---

- [ ] **Unit 2: Add `list_ai_sessions_for_workflow/1` to `Destila.AI`**

**Goal:** Provide a context function returning all AI sessions for a workflow session, ordered newest-first.

**Requirements:** R1.

**Dependencies:** None.

**Files:**
- Modify: `lib/destila/ai.ex`
- Test: `test/destila/ai_test.exs` (create if missing; otherwise extend)

**Approach:**
- Mirror `get_ai_session_for_workflow/1`: same `from(s in Session, where: s.workflow_session_id == ^workflow_session_id, order_by: [desc: s.inserted_at])` but without `limit`, and return via `Repo.all/1`.
- Return an empty list (not nil) when no sessions exist — matches Ecto's `Repo.all` default.
- Optionally add a `get_ai_session!/1` for the detail page (simple `Repo.get!(Session, id)`), or reuse `Repo.get` directly in the LiveView. Decision: add `get_ai_session/1` (plain) and have the LiveView convert `nil` into a flash redirect. This matches the TerminalLive pattern.

**Patterns to follow:**
- `Destila.AI.get_ai_session_for_workflow/1` query structure.

**Test scenarios:**
- Happy path: returns the list of sessions ordered by `inserted_at` descending.
- Edge case: returns `[]` when the workflow has no AI sessions.
- Edge case: filters out sessions belonging to a different workflow.
- Happy path: `get_ai_session/1` returns the session when the id exists.
- Edge case: `get_ai_session/1` returns `nil` for an unknown id (no raise).

**Verification:**
- The function is used by both the sidebar (Unit 3) and the detail page (Unit 4) without extra DB calls.

---

- [ ] **Unit 3: Render "AI Sessions" section in the workflow runner right sidebar**

**Goal:** Show the AI sessions list between the "Workflow Session" and "Exported Metadata" sections, with live aliveness dots and navigation to the detail page.

**Requirements:** R1, R2, R3, R14.

**Dependencies:** Unit 1 (for `alive_ai?/1` and `{:aliveness_changed_ai, ...}` messages), Unit 2 (for the list function).

**Files:**
- Modify: `lib/destila_web/live/workflow_runner_live.ex`
- Test: `test/destila_web/live/ai_session_sidebar_live_test.exs` (create)

**Approach:**
- In `mount_session/2` (currently ~line 30), load `AI.list_ai_sessions_for_workflow/1` and assign as `:ai_sessions`. Also build an initial `:ai_sessions_alive` map `%{ai_id => alive?}` by calling `AlivenessTracker.alive_ai?/1` for each id.
- When `connected?(socket)`, the existing subscription to `AlivenessTracker.topic()` is sufficient — the tracker now broadcasts both `{:aliveness_changed, ws_id, alive?}` and `{:aliveness_changed_ai, ai_id, alive?}` on the same topic.
- Add a new `handle_info({:aliveness_changed_ai, ai_id, alive?}, socket)` clause that updates `:ai_sessions_alive` if `ai_id` is in the loaded list. Ignore otherwise.
- After any `assign_ai_state` call where a new AI session might have been created (e.g., `start_workflow`, `continue_workflow`, `next_phase`), refresh the `:ai_sessions` list. Simplest is to fold a helper `assign_ai_sessions_list/2` into `assign_ai_state/2` since that function is already the seam for ai-related state rebuilds.
- Render the new section inside `#metadata-sidebar-content`, between the existing divider (`<div class="border-t border-base-300/60 mx-3">`) at ~line 863 and the Exported Metadata `<div class="px-3 pt-3 pb-6 flex-1">` at ~line 866. Add a second matching divider below the new section so the three-block rhythm is preserved.
- Section structure: an `<h3>` with the "AI Sessions" label and the same `[10px] uppercase tracking-wider` type used for "Workflow Session"/"Exported Metadata", then either an empty-state paragraph (`"No AI sessions yet"`) or a `<ul>`/`<div class="space-y-0.5">` of rows.
- Each row: a `<.link navigate={~p"/sessions/#{ws_id}/ai/#{ai.id}"}>` with a leading `<.aliveness_dot session={@workflow_session} alive?={...} phase_status={:idle} />` (or similar neutral phase_status), a creation date formatted like `Calendar.strftime(ai.inserted_at, "%b %-d, %H:%M")`, and (optional) a truncated `claude_session_id` suffix. Explicit DOM id `id={"ai-session-row-#{ai.id}"}`.
- Section wrapper gets `id="ai-sessions-section"` so tests can assert on its presence.

**Patterns to follow:**
- Row layout mirrors `#view-user-prompt-btn` and `#open-terminal-btn` above it.
- `<.aliveness_dot>` already handles all three visual states.
- `assign_metadata/2` and `assign_worktree_path/2` are good shape templates for a new `assign_ai_sessions_list/2` helper.

**Test scenarios:**
- Happy path: sidebar shows 2 rows when the workflow has 2 AI sessions (`#ai-session-row-<id>` selector).
- Happy path: each row is a `<.link navigate={...}>` pointing to `/sessions/:ws_id/ai/:ai_id` — assert href.
- Happy path: empty state is rendered (`#ai-sessions-section` contains "No AI sessions yet" text) when no AI sessions exist.
- Happy path: row shows green aliveness class when `AlivenessTracker.alive_ai?/1` is true at mount.
- Happy path: row shows muted aliveness class when not running at mount.
- Integration: broadcasting `{:aliveness_changed_ai, ai_id, true}` on `AlivenessTracker.topic()` flips the dot to green without a page reload.
- Integration: broadcasting `{:aliveness_changed_ai, ai_id, false}` flips the dot back to muted.
- Edge case: clicking a row navigates to the detail page (verify via `render_click` + `push_navigate` assertion or `assert_patched/_redirect`).
- Edge case: header aliveness dot (existing `{:aliveness_changed, ws_id, alive?}` handler) still toggles independently.

**Verification:**
- The new section lives inside the existing collapsible sidebar and toggles away with the rest of the content when the user collapses it.
- Existing Crafting Board aliveness behavior is untouched.

---

- [ ] **Unit 4: Add route + `DestilaWeb.AiSessionDetailLive` skeleton**

**Goal:** Stand up the detail page with header, mount logic, subscription, empty states, and back-navigation — but without the content-block rendering (deferred to Unit 6).

**Requirements:** R4, R5, R12, R13 (indirect).

**Dependencies:** Unit 1 (aliveness) and Unit 2 (`get_ai_session/1`). Unit 5 optional but helpful for testing — can be stubbed with a direct ClaudeCode.Session call if Unit 5 lands later.

**Files:**
- Modify: `lib/destila_web/router.ex`
- Create: `lib/destila_web/live/ai_session_detail_live.ex`
- Test: `test/destila_web/live/ai_session_detail_live_test.exs` (create)

**Approach:**
- Router: add `live "/sessions/:workflow_session_id/ai/:ai_session_id", AiSessionDetailLive` inside the existing `scope "/", DestilaWeb` block, adjacent to the other `/sessions/:id...` routes. Module becomes `DestilaWeb.AiSessionDetailLive`.
- Mount signature: `mount(%{"workflow_session_id" => ws_id, "ai_session_id" => ai_id}, _session, socket)`.
- Lookup sequence:
  1. `workflow_session = Workflows.get_workflow_session(ws_id)` — nil → `put_flash` + `push_navigate(~p"/crafting")`.
  2. `ai_session = AI.get_ai_session(ai_id)` — nil → `put_flash` + `push_navigate(~p"/sessions/#{ws_id}")`.
  3. Verify `ai_session.workflow_session_id == ws_id`; on mismatch, same redirect as (2) with a flash like "AI session does not belong to this workflow".
- `connected?(socket)` → subscribe to `AlivenessTracker.topic()`; seed `:alive?` with `AlivenessTracker.alive_ai?/1`.
- Load messages (with Unit 5 adapter): `History.get_messages(ai_session.claude_session_id)`:
  - `nil` claude_session_id → `history_state = :missing` (no call made).
  - `{:ok, []}` → `:empty`.
  - `{:ok, msgs}` → `{:loaded, msgs, build_tool_index(msgs)}`.
  - `{:error, reason}` → log `Logger.warning/1`, `:error`.
- `page_title` like `"AI Session — #{ws.title}"`.
- Render (pre-Unit-6): `Layouts.app` wrapper; header with back-link (`<.link navigate={~p"/sessions/#{ws_id}"}>` + `hero-arrow-left-micro`), workflow session title, and a card/strip showing creation date and `claude_session_id` (copyable via `<code>`), plus the live aliveness dot. Below the header: a placeholder `<div id="ai-session-conversation">` with an empty-state component for `:missing`/`:empty`/`:error`, and a `No conversation history available` message styled consistently.
- Handle aliveness update: `handle_info({:aliveness_changed_ai, ^ai_id, alive?}, socket)` updates `:alive?`. Ignore other ids.

**Patterns to follow:**
- `DestilaWeb.TerminalLive` for mount validation + layout.
- `Layouts.app flash={@flash} page_title={@page_title}` wrapper.

**Test scenarios:**
- Happy path: mounting with a valid ws_id + ai_id renders the header (`#ai-session-header`) including the creation date and the claude_session_id string.
- Happy path: back link navigates to `/sessions/:ws_id`.
- Edge case: unknown workflow_session_id redirects to `/crafting` with a flash.
- Edge case: unknown ai_session_id redirects to the parent workflow page with a flash.
- Edge case: ai_session belongs to a different workflow_session_id → redirect with a flash.
- Edge case: `claude_session_id` is `nil` → renders the "No conversation history available" empty state.
- Edge case: adapter returns `{:ok, []}` → renders empty state.
- Edge case: adapter returns `{:error, :enoent}` → renders empty state and emits a warning log.
- Integration: broadcasting `{:aliveness_changed_ai, ai_id, true}` on `AlivenessTracker.topic()` toggles the detail-page aliveness dot live.

**Verification:**
- The page renders in all error/empty paths without raising.
- `@page_title` is set, so the browser tab title picks up the session title.

---

- [ ] **Unit 5: `Destila.AI.History` adapter for `ClaudeCode.History.get_messages/2`**

**Goal:** Make the history read swappable in tests without stubbing a module we do not own.

**Requirements:** Enables R6, R7, R11, R12.

**Dependencies:** None (pure refactor/seam).

**Files:**
- Create: `lib/destila/ai/history.ex`
- Modify: `config/test.exs` (set the test implementation)
- Test: `test/destila/ai/history_test.exs` (create; minimal)
- Create: `test/support/fake_history.ex` (test helper storing canned responses via `Application.put_env` or an `Agent`/ETS store)

**Approach:**
- `Destila.AI.History` exposes `get_messages/1` and `get_messages/2`. Delegate to the real implementation by default:
  - `Application.get_env(:destila, :ai_history_module, ClaudeCode.History).get_messages(session_id, opts)`. **Default target is `ClaudeCode.History`** — verified string-session-id API. Not `ClaudeCode.Session`, which expects a live PID.
- Return contract: `{:ok, [%ClaudeCode.History.SessionMessage{}]} | {:error, term()}`, matching the upstream `@spec`.
- The module doubles as a safety wrapper: it rescues any exception from the underlying call and returns `{:error, {:exception, ...}}` so the LiveView's `{:error, _}` branch covers unexpected shapes/crashes from disk/parse failures.
- In `config/test.exs`, set `config :destila, :ai_history_module, Destila.AI.FakeHistory`.
- The fake history module stores `{session_id => {:ok, messages} | {:error, reason}}` in an `Agent` (or process dictionary or ETS keyed by test pid via `nimble_ownership`-style if we want async). Tests call `FakeHistory.stub(session_id, {:ok, messages})` in their `setup`.
- Build convenience fixtures: `Destila.AI.HistoryFixtures` with tiny builders like `text_message/1`, `thinking_message/1`, `tool_use_pair/3`, etc., so rendering tests stay readable. Each builder returns a fully-formed `%ClaudeCode.History.SessionMessage{}` so the renderer tests exercise the real struct, not a loose map.

**Patterns to follow:**
- `ClaudeCode.Test.stub/2` in the existing tests as conceptual inspiration, but we own this adapter so we can expose whatever API reads cleanly.

**Test scenarios:**
- Happy path: delegates to the configured module; default config calls `ClaudeCode.History.get_messages/2` (verified via a stand-in module that records the call).
- Edge case: when the underlying call raises, the adapter returns `{:error, {:exception, ...}}` instead of propagating.
- Integration: in test env, `Destila.AI.History.get_messages(id)` returns exactly what `FakeHistory.stub/2` provided.

**Verification:**
- The LiveView never imports `ClaudeCode.History` or `ClaudeCode.Session` directly; it only calls `Destila.AI.History.get_messages/1`.
- Tests can drive arbitrary history shapes (including `{:ok, []}`, `{:error, :enoent}`, and rich content-block fixtures) without touching disk.

---

- [ ] **Unit 6: `DestilaWeb.AiSessionDebugComponents` + full renderer wired into the detail page**

**Goal:** Render every content block type, pair tool calls with tool results, gracefully handle unknown shapes.

**Requirements:** R6, R7, R8, R9, R10, R11.

**Dependencies:** Units 4 and 5.

**Files:**
- Create: `lib/destila_web/components/ai_session_debug_components.ex`
- Modify: `lib/destila_web/live/ai_session_detail_live.ex` (wire the renderer in, build the tool_use index at mount time, pass both into the template)
- Test: `test/destila_web/live/ai_session_detail_live_test.exs` (extend with block-by-block coverage)

**Approach:**
- Module exposes a single primary function component `session_history/1` that takes `messages:` and `tool_index:`. Internally it iterates messages and dispatches each content block to a smaller component via a pattern-matching dispatcher:
  - `content_block/1` — function component; first argument is the block struct; delegates via a `case` on struct module.
- Message-level rendering:
  - `type: :user` + binary content → `user_text_bubble/1`.
  - `type: :user` + list content → iterate list with `content_block/1`.
  - `type: :assistant` → iterate `message[:content]` list with `content_block/1`.
  - Tolerate `message` being a raw map: use `get_in(message, [:content]) || get_in(message, ["content"])` and `List.wrap/1` for non-list shapes. Non-list / non-binary content falls through to the generic fallback renderer.
- Per-block rendering (each is a small function or one branch in `content_block/1`):
  - `TextBlock` — render `text` via the existing markdown renderer if that is easy; plain `<p>` with `whitespace-pre-wrap` is a safe fallback. Citations rendered beneath as a small list when present.
  - `ThinkingBlock` — `<details>` collapsed by default; `<summary>` "Thinking (click to expand)"; `<pre>` of `thinking`. Signature hidden unless a debug flag is flipped.
  - `RedactedThinkingBlock` — subtle placeholder "[Redacted thinking — #{byte_size(data)} bytes]".
  - `ToolUseBlock` — header row with tool name + id; pretty JSON `<pre>` of `input` via `Jason.encode!(input, pretty: true)`. Add `id={"tool-use-#{id}"}` as the anchor for its result.
  - `ToolResultBlock` — find `tool_use_index[tool_use_id]`; render a nested card under/beside the tool_use with name carried over and `is_error` → red border/background. Content is string → `<pre>`, list of TextBlocks → iterate text.
  - `ServerToolUseBlock` / `ServerToolResultBlock` — same shape; label "server tool: web_search" etc.; result `:type` shown as a small badge.
  - `MCPToolUseBlock` / `MCPToolResultBlock` — same shape plus `server_name` badge.
  - `ImageBlock` — render `<img src={...}>` for URLs; for base64, render a placeholder card "Image — base64, #{kb} KB" (don't decode a megabyte of b64 into the DOM). Decision reason: avoids DOM blow-up; still communicates presence.
  - `DocumentBlock` — placeholder card with title + context.
  - `ContainerUploadBlock` — placeholder card "Uploaded file: #{file_id}".
  - `CompactionBlock` — full-width horizontal marker "--- Conversation compacted ---" with the compaction content collapsed by default.
  - Catch-all clause `_ ->` renders `<pre class="text-xs">#{inspect(block, pretty: true, limit: :infinity)}</pre>` inside a subdued card.
- Visual separation: assistant content is right-aligned or uses a distinct background (bg-base-200), user content uses a different background (bg-primary/10) or left alignment.
- Tool pairing: the simplest approach is to walk messages top-to-bottom in order and render each block in place. Since `ToolResultBlock` sometimes arrives in a follow-up user message, rendering it *at that point in the stream* plus showing the resolved tool_use name from `tool_index[tool_use_id]` satisfies the "visually paired" requirement without reordering messages. Optional enhancement: nest the ToolResultBlock visually beneath the ToolUseBlock using the `id="tool-use-#{id}"` anchor — can be done with a small CSS rule or an arrow icon pointing up to the originating tool_use.
- Each rendered block gets a stable DOM id (e.g., `data-block-type="tool_use"` + `id="block-#{uuid}-#{index}"`) for testability.

**Patterns to follow:**
- `lib/destila_web/components/chat_components.ex` function component structure and Tailwind vocabulary.
- `Jason.encode!(value, pretty: true)` for JSON prettifying (Jason is already a transitive dep).
- Tests in `test/destila_web/live/markdown_metadata_viewing_live_test.exs` for how to assert on rendered HTML with `has_element?/2`.

**Test scenarios (drive via `FakeHistory.stub` with hand-built fixtures):**
- Happy path: a user text message and an assistant text message render in order, with different classes/selectors distinguishing them.
- Happy path: a `ThinkingBlock` renders inside a `<details>` element; its content is not visible until expanded (assert via selector that `<details>` lacks the `open` attribute).
- Happy path: a `RedactedThinkingBlock` renders a visible placeholder.
- Happy path: a `ToolUseBlock` renders tool name, id, and pretty JSON of its input; presence assertable via `data-block-type="tool_use"`.
- Happy path: a `ToolUseBlock` + `ToolResultBlock` share the `tool_use_id` and the rendered result carries a visual link (e.g., `data-tool-use-ref="#{id}"` attribute or `data-tool-name` pulled from the tool_index).
- Error path: a `ToolResultBlock` with `is_error: true` renders with an error class (e.g., `text-error` or `border-error`).
- Happy path: a `ServerToolUseBlock`/`ServerToolResultBlock` pair renders with a "server tool" badge.
- Happy path: an `MCPToolUseBlock` renders with its `server_name` and `name` visible.
- Happy path: an `ImageBlock` with a URL source renders an `<img>`; a base64 `ImageBlock` renders a placeholder card without embedding the bytes.
- Happy path: a `CompactionBlock` renders a visible compaction marker.
- Edge case: an `%{__struct__: NotARealBlock}` struct renders as a `<pre>` fallback with `inspect/2` output and does not crash.
- Edge case: a `SessionMessage` whose `:message` is a raw map (parser fallback) renders a fallback summary without raising.
- Edge case: a `SessionMessage` whose `:message[:content]` is a binary (for `type: :user`) renders as plain text.
- Edge case: empty `content` list renders nothing (no layout breakage).

**Verification:**
- All Gherkin scenarios in `features/ai_session_detail.feature` pass.
- The page renders with the full block zoo in a single fixture without crashing.

---

- [ ] **Unit 7: Gherkin features + test linkage**

**Goal:** Commit the two `.feature` files from the prompt and ensure every LiveView test carries the matching `@tag feature:/scenario:`.

**Requirements:** R15.

**Dependencies:** Units 3, 4, 6 (the tests live in those unit's test files).

**Files:**
- Create: `features/ai_session_sidebar.feature`
- Create: `features/ai_session_detail.feature`
- Modify: `test/destila_web/live/ai_session_sidebar_live_test.exs`
- Modify: `test/destila_web/live/ai_session_detail_live_test.exs`

**Approach:**
- Copy the Gherkin from the prompt verbatim into the two feature files.
- Ensure the `@moduledoc` of each LiveView test module links back to its feature file (`Feature: features/ai_session_sidebar.feature`).
- Ensure every test carries `@tag feature: "...", scenario: "..."` matching an existing scenario in the feature file.
- Cross-check that every scenario in the feature file has at least one linked test. For scenarios that are covered by logic-level tests in Unit 1 (not a LiveView test), carry the tag on the closest LiveView test that observes the effect.
- Run `mix test --only feature:ai_session_sidebar` and `mix test --only feature:ai_session_detail` to confirm linkage.

**Patterns to follow:**
- `features/exported_metadata.feature` and `test/destila_web/live/open_terminal_live_test.exs` for tag format.

**Test scenarios:**
- Test expectation: none — this unit only adds feature files and `@tag` metadata. Correctness is verified by `mix test --only feature:...` returning nonzero test count and by a cross-reference check that every scenario title appears in at least one test.

**Verification:**
- `mix test --only feature:ai_session_sidebar` runs at least one test per scenario in that feature.
- `mix test --only feature:ai_session_detail` runs at least one test per scenario in that feature.

---

- [ ] **Unit 8: Precommit run and polish**

**Goal:** Run `mix precommit`, fix any lint/type/test issues, and do one manual pass of the UI in the browser.

**Requirements:** All R-requirements indirectly.

**Dependencies:** Units 1–7.

**Files:**
- None new — fixes only.

**Approach:**
- `mix precommit` (covers formatter, compile-warnings-as-errors, tests — per `CLAUDE.md` guidance).
- Start the server with `elixir --sname destila -S mix phx.server`, create a workflow session that reaches the point of having at least one AI session with a `claude_session_id`, open the workflow runner, and verify:
  - AI Sessions section appears between Workflow Session and Exported Metadata.
  - Aliveness dot is green while the GenServer is alive.
  - Collapse/expand of the sidebar still works (the new section hides with the rest).
  - Clicking a row opens the detail page.
  - Detail page shows header + conversation.
  - Back navigation returns to the workflow runner.
- Verify a session with no `claude_session_id` renders the empty state.

**Patterns to follow:**
- `CLAUDE.md` ops guidance (remote shell + `mix precommit`).

**Test scenarios:**
- Test expectation: none — final integration verification; any regressions become fixes in prior units.

**Verification:**
- `mix precommit` is green.
- Manual UI exploration passes the five checks above.

## System-Wide Impact

- **Interaction graph:** The AlivenessTracker is the hub. `ClaudeSession` broadcasts to it; it broadcasts to all LiveViews subscribed on `"session_aliveness"` (currently the workflow runner and the Crafting Board; now also the AI Session Detail page). Adding a second broadcast message type (`:aliveness_changed_ai`) on the same topic means every existing subscriber receives an extra message per AI state change — cost is trivial (a pattern match that falls through) but worth naming.
- **Crafting Board compatibility verified.** `DestilaWeb.CraftingBoardLive` (`lib/destila_web/live/crafting_board_live.ex:77`) already has a `def handle_info(_msg, socket), do: {:noreply, socket}` catch-all after its existing `{:aliveness_changed, ws_id, alive?}` clause, so the new `:aliveness_changed_ai` broadcast is dropped silently there with no code change required. The existing `{:aliveness_changed, ws_id, alive?}` handler continues to update `:alive_sessions` as before.
- **Workflow runner compatibility verified.** `DestilaWeb.WorkflowRunnerLive.handle_info({:aliveness_changed, ws_id, alive?}, socket)` (~line 468) matches only the 3-tuple workflow form. A new `{:aliveness_changed_ai, ai_id, alive?}` clause is added for the sidebar (Unit 3); neither handler disturbs the other.
- **Error propagation:** `History.get_messages/1` is the only new disk-touching call. It is wrapped in a rescue at the adapter level, and the LiveView treats `{:error, _}` as the empty-state branch. No error path crashes the LiveView.
- **State lifecycle risks:** The ETS table in `AlivenessTracker` grows by one entry per running AI session. Entries are removed on `:DOWN`, and because ClaudeSession processes have an inactivity timer (5 min default), stale `{:ai, id}` entries clear naturally. The only lingering concern is a restart of the tracker itself — its init now walks the Registry and (optionally) the DB to rehydrate `{:ai, id}` entries; if the DB lookup fails, `{:workflow, ws_id}` is still correct, preserving existing behavior.
- **API surface parity:** `alive?/1` semantics are explicitly preserved for the Crafting Board and the workflow runner header. The new `alive_ai?/1` function is purely additive. No public function is renamed or removed.
- **Integration coverage:** An integration test in `ai_session_sidebar_live_test.exs` broadcasts the new `:aliveness_changed_ai` message on `AlivenessTracker.topic()` and asserts the dot flips — this validates the PubSub wiring end-to-end, not just the handler logic.
- **Unchanged invariants:** The 1-to-1 relationship between `workflow_session_id` and a running `ClaudeSession` in the Registry is not changed; the header aliveness dot keeps its workflow-level meaning; the existing `get_ai_session_for_workflow/1` (latest only) still exists and is still used by `WorkflowRunnerLive.assign_worktree_path/2`.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| claude_code history API shape drift on package upgrade | Verified at plan time against installed deps: use `ClaudeCode.History.get_messages/2` (`@spec get_messages(session_id(), keyword()) :: {:ok, [SessionMessage.t()]} | {:error, term()}`). Still wrap the call in `Destila.AI.History` with a rescue so future shape/parse changes fall into the `{:error, _}` empty-state branch. The `limit:`/`offset:` opts are already accepted upstream, so pagination is a future one-line change. |
| Tracker dual-key rehydrate misses an ai_session_id after a crash/restart | The detail page and sidebar both call `alive_ai?/1`; worst case is a muted dot on a currently-running session until the next `{:claude_session_started, ...}` broadcast. Acceptable. Next broadcast (idle timer end or next user turn) will correct it. A `Logger.debug/1` line when rehydrate can't find an ai_session for a running ws_id makes this observable without noise. |
| Large JSONL files (long conversations) block the LiveView mount | MVP reads the whole file synchronously. Acceptable for current session sizes. Add `limit:`/`offset:` via `get_messages/2` if users complain; the adapter already takes a keyword list. |
| Broadcast storm when an AI session turns over quickly | Two broadcasts per state transition instead of one. At the current workload this is not a concern; noted for future scaling. |
| Renderer crashes on a new content block type shipped by claude_code | Catch-all `inspect/2` fallback plus a dedicated test asserting an unknown struct does not crash. |
| Existing callers of `alive?/1` still expect workflow semantics | Preserved explicitly — the ETS key change (`{:workflow, ws_id}`) is encapsulated behind the same function signature. A test asserts `alive?(ws_id)` returns the expected value after the refactor. |
| Test coverage gap: history fixtures drift from the real library shapes | Include at least one test that round-trips a realistic hand-built `%ClaudeCode.History.SessionMessage{}` (aliased struct, not a plain map) to catch schema drift when the claude_code package upgrades. |

## Documentation / Operational Notes

- No runbook changes — this is an in-app debugging surface.
- Feature files in `features/` serve as the user-facing documentation for behavior; they are the contract for the tests.
- No config changes required in production; `config/test.exs` gets the `Destila.AI.FakeHistory` wiring.

## Sources & References

- **Origin:** direct user prompt (no `docs/brainstorms/` requirements document).
- Relevant code:
  - `lib/destila/ai/aliveness_tracker.ex`
  - `lib/destila/ai.ex` (`get_ai_session_for_workflow/1`)
  - `lib/destila/ai/session.ex`
  - `lib/destila/ai/claude_session.ex`
  - `lib/destila/ai/conversation.ex`
  - `lib/destila/ai/session_config.ex` (verified insertion point for `ai_session_id` opt)
  - `lib/destila/workers/ai_query_worker.ex` (verified `ClaudeSession.for_workflow_session/2` call site)
  - `lib/destila_web/live/workflow_runner_live.ex` (right sidebar at ~lines 695–900)
  - `lib/destila_web/live/crafting_board_live.ex` (existing aliveness subscriber with catch-all `handle_info/2`)
  - `lib/destila_web/live/terminal_live.ex` (detail-page shape reference)
  - `lib/destila_web/router.ex`
  - `lib/destila_web/components/board_components.ex` (`aliveness_dot/1`)
  - `lib/destila_web/components/chat_components.ex` (componentization reference)
- Installed deps (read directly):
  - `deps/claude_code/lib/claude_code/history.ex` — `get_messages/2` spec and body
  - `deps/claude_code/lib/claude_code/session.ex` — PID-based `get_messages/2` (not used here)
  - `deps/claude_code/lib/claude_code/history/session_message.ex` — struct shape and parser fallback behavior
- External docs:
  - `ClaudeCode.Session` and history: https://github.com/guess/claude_code/blob/main/docs/guides/sessions.md
  - `%ClaudeCode.History.SessionMessage{}`: https://github.com/guess/claude_code/blob/main/lib/claude_code/history/session_message.ex
  - `ClaudeCode.Content.*` structs: https://github.com/guess/claude_code/tree/main/lib/claude_code/content/
