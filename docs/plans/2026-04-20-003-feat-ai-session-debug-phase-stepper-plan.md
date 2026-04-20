---
title: Add Phase Stepper to AI Session Debug Detail Page
type: feat
status: active
date: 2026-04-20
---

# Add Phase Stepper to AI Session Debug Detail Page

## Overview

Add a horizontal phase stepper to the AI Session Debug Detail page header
(`lib/destila_web/live/ai_session_detail_live.ex`, route
`/sessions/:workflow_session_id/ai/:ai_session_id`) that:

1. Renders one step per workflow phase in defined order, using `Destila.Workflows.phase_name/2`
   and `Destila.Workflows.total_phases/1` keyed off `workflow_session.workflow_type`.
2. Shows per-phase aggregated stats (cost, duration, input/output tokens, turn count,
   wall-clock time) for phases that have `Destila.AI.Message` rows.
3. Highlights the step matching `workflow_session.current_phase`.
4. Makes each clickable step an anchor link that scrolls smoothly to a newly-injected
   `#phase-separator-{N}` divider rendered inline inside the existing conversation list.
5. Updates live on the same cadence as `usage_totals` (debounced `:reload_history`
   path on `{:ai_stream_chunk, _}` and the `{:message_added, _}` path).

No schema changes, no new dependencies, no new PubSub subscriptions.

## Problem Frame

The AI Session Debug Detail page already renders the full JSONL conversation history
plus a totals strip, but there is no way to see how a session's turns are distributed
across the workflow's phases (e.g. phase 1 "Task Description" → phase 4 "Prompt
Generation" in `BrainstormIdeaWorkflow`). Engineers debugging a session have to
scroll the entire transcript and infer phase boundaries from timestamps in the raw
JSONL file. The workflow already tracks the current phase on `workflow_session.current_phase`,
and every stored `%Destila.AI.Message{}` has a `:phase` integer — this plan surfaces
that structure as a first-class navigational stepper and as inline dividers in the
transcript.

## Requirements Trace

- **R1.** Render a horizontal phase stepper in the page header, above the conversation
  container, with one step per workflow phase in defined order.
- **R2.** Each step shows the phase name (`Destila.Workflows.phase_name/2`) and the
  total count from `Destila.Workflows.total_phases/1`.
- **R3.** For each phase with recorded `AI.Message` rows, display: cost (USD),
  summed duration, input tokens, output tokens, turn count, and wall-clock time.
- **R4.** The step whose phase number equals `workflow_session.current_phase`
  renders with an active/highlighted style; others render with a non-active style.
- **R5.** Phases with no `AI.Message` rows in this AI session render visibly but
  without stats and are not clickable.
- **R6.** Clickable phases render as `<a href="#phase-separator-{N}">` anchor links;
  the scrollable conversation container uses `scroll-behavior: smooth` so jumps
  animate.
- **R7.** For each phase with a resolvable boundary, a `#phase-separator-{N}` divider
  is injected into the rendered conversation, positioned immediately before that
  phase's first JSONL entry, labelled with the phase name.
- **R8.** Phase 1's separator always renders at the top of the conversation list
  (when any entries exist).
- **R9.** For phase N > 1, the separator is placed before the first JSONL entry whose
  timestamp is greater than `max(AI.Message.inserted_at where phase = N-1)` for this
  AI session.
- **R10.** If no `AI.Message` exists for phase N-1, no separator is rendered for
  phase N and its stepper step is treated as empty (non-clickable, no stats).
- **R11.** Wall-clock per phase = `max(entry_ts) - min(entry_ts)` over JSONL entries
  assigned to that phase's bucket.
- **R12.** Stepper stats and separator placement recompute in the same code paths that
  currently recompute `usage_totals` — `{:ai_stream_chunk, _}` (after debounced
  `:reload_history` fires) and `{:message_added, %AI.Message{ai_session_id: ^id}}`.
  No new PubSub subscriptions.
- **R13.** Provide stable DOM ids for the stepper (`#ai-session-phase-stepper`), each
  step (`#phase-step-{N}`), and each separator (`#phase-separator-{N}`) so tests can
  target them with `Phoenix.LiveViewTest.element/2` and `has_element?/2`.
- **R14.** Extend `features/ai_session_detail.feature` with the new scenarios listed
  in the user prompt. All existing scenarios keep passing.
- **R15.** Add linked tests under `test/destila_web/live/ai_session_detail_live_test.exs`,
  each tagged with `@tag feature: "ai_session_detail", scenario: "..."` matching the
  new scenario names.

## Scope Boundaries

- Not adding a new PubSub subscription; updates piggyback on the existing
  `:ai_stream_chunk` / `:message_added` signals.
- Not adding JavaScript hooks. Smooth scroll uses CSS `scroll-behavior: smooth` on
  the existing scroll container only.
- Not changing the `Destila.AI.Message` schema or any migration.
- Not removing or restyling the existing `usage_totals_strip/1` — the stepper
  coexists with it.
- Not adding keyboard navigation/focus semantics beyond what a plain `<a href>` gives.
- Not persisting phase wall-clock computations; they are recomputed on each
  `history_state` refresh.
- Not changing how `Destila.AI.Message.phase` is populated anywhere upstream — the
  plan assumes phase values already exist.

## Context & Research

### Relevant Code and Patterns

- `lib/destila_web/live/ai_session_detail_live.ex` — LiveView under edit.
  - `mount_with_session/3` (line 56) is where `:usage_totals` is assigned on mount.
  - `handle_info({:ai_stream_chunk, _}, socket)` (line 86) schedules a debounced
    `:reload_history`.
  - `handle_info(:reload_history, socket)` (line 90) calls `refresh_history/1` — this
    is the canonical place to recompute `history_state`. It currently only updates
    items from `History.read_all/1` but does **not** recompute `usage_totals` there;
    totals recompute on `{:message_added, _}` (line 94).
  - `normalize_entry/1` (line 168) drops the raw JSONL entry `"timestamp"` for
    `:msg` items (converting to `%SessionMessage{}`). Preserving timestamps is the
    plan's biggest plumbing change.
  - `render/1` header block (lines 213–246) is where the stepper mounts; the
    scrollable container is the `<div class="flex-1 min-h-0 overflow-y-auto">` at
    line 248.
  - `<.session_history items={items} tool_index={tool_index} />` at line 270 is the
    single call site for transcript rendering.
- `lib/destila_web/components/ai_session_debug_components.ex` — host for the new
  `phase_stepper/1` function component and for an additional `session_item` branch
  that renders a separator tuple. The existing `session_history/1` (line 37) iterates
  `@items` with `Enum.with_index` and dispatches to `session_item/1`; the simplest
  injection is a new pattern match on `{:separator, phase_num, phase_name}` inside
  `session_item/1`.
- `lib/destila/ai.ex` — context module for new `aggregate_usage_by_phase/1` and
  `phase_boundaries_for_ai_session/1`:
  - `aggregate_usage_for_ai_session/1` (line 99) shows the exact shape that
    `aggregate_usage_by_phase/1` should group by phase.
  - `empty_usage_totals/0` (line 105) is the zero-value map both aggregators use.
  - `list_messages_for_ai_session/1` (line 82) is the base query — new functions
    reuse it to preserve the ordering-by-`inserted_at` guarantee the UI depends on.
- `lib/destila/ai/message.ex` — `phase` field (line 12, default 1) is already on the
  schema and migration-safe.
- `lib/destila/workflows.ex` — `phase_name/2` (line 73), `total_phases/1` (line 72)
  already exist and are the canonical lookups.
- `lib/destila_web/components/ai_session_debug_components.ex` usage chip helpers
  (`usage_tooltip/1`, `format_int/1`) are the existing pattern for rendering cost,
  input/output/cache tokens; the stepper reuses their formatting style.
- `deps/claude_code/lib/claude_code/history/session_message.ex` — `%SessionMessage{}`
  has no `timestamp` field; the per-entry timestamp lives only on the raw JSONL
  entry at key `"timestamp"` (ISO-8601 string, verified by inspecting a sample
  `.jsonl` file — keys `parentUuid, isSidechain, userType, cwd, sessionId, version,
  gitBranch, agentId, type, message, uuid, timestamp`). The LiveView must parse and
  preserve this before `normalize_entry/1` converts user/assistant entries into
  `%SessionMessage{}`.
- `test/destila_web/live/ai_session_detail_live_test.exs` — existing test file.
  `insert_system_message_with_usage/3` (line 797) and `usage_raw/3` (line 809) are
  the fixture helpers to reuse for seeding per-phase messages. `FakeHistory.stub/2`
  and `FakeHistory.stub_raw/2` (referenced at lines 102, 678) provide deterministic
  JSONL fixtures; `stub_raw` accepts raw maps with `"timestamp"` so the tests can
  control entry timestamps precisely.
- `features/ai_session_detail.feature` — the Feature prose and existing scenarios
  live here. The new scenarios append after the last existing scenario (line 176,
  "Totals strip updates live when a new turn is recorded").

### Institutional Learnings

No matching entries were found in `docs/solutions/` for phase-stepper UI. The closest
adjacent pattern is the "AI Sessions Sidebar + Debug Detail" plan
(`docs/plans/2026-04-16-001-feat-ai-sessions-sidebar-and-debug-detail-plan.md`)
which established the `AiSessionDebugComponents` module and the `history_state`
assign tagged-tuple shape.

### External References

None required — this is an internal UI feature built from existing primitives. Tailwind
`scroll-smooth` / `scroll-behavior: smooth` is the only CSS dependency and is already
available in Tailwind v4 (project uses Tailwind v4 via `assets/css/app.css`).

## Key Technical Decisions

- **Preserve per-entry timestamps as a parallel list in `history_state`, not on the
  item tuple.** The existing `session_item/1` component branches on
  `{:msg, %SessionMessage{}}` and `{:meta, map}` — changing the arity of those tuples
  would fan out breakage across all branches. Instead, `history_state` grows a
  sibling list `entry_times :: [DateTime.t() | nil]` indexed identically to `items`.
  Bucket assignment and wall-clock are computed server-side before render; the
  renderer stays unaware of timestamps.
- **Bucket entries into phases once per refresh, compute separator insertion points
  and wall-clocks up front.** The LiveView builds a `phase_buckets :: %{1..N => {first_ts,
  last_ts, first_item_idx}}` and a `separator_targets :: %{item_idx => phase_num}`
  map inside `refresh_history/1` and `mount_with_session/3`. The render path merges
  separator tuples into the items list based on `separator_targets` — no recomputation
  per frame.
- **Render separators as `{:separator, phase_num, phase_name}` pseudo-items merged
  into the items list at render time.** This keeps the `session_history/1` contract
  (a flat list dispatched via `session_item/1`) intact and avoids a second rendering
  pass. The new `session_item/1` branch emits the divider with the stable
  `#phase-separator-{N}` id.
- **Compute phase boundaries via two new context functions, not via ad-hoc queries in
  the LiveView.** `AI.aggregate_usage_by_phase/1` returns `%{phase_number =>
  totals_map}` mirroring `aggregate_usage_for_ai_session/1`. `AI.phase_boundaries_for_ai_session/1`
  returns `%{phase_number => max_inserted_at_datetime}`. Both reuse
  `list_messages_for_ai_session/1` to keep query shape consistent.
- **Recompute stepper assigns in all three existing hooks where transcript or
  usage state changes.** On mount, on `:reload_history` fire (after a
  `:ai_stream_chunk`), and on `{:message_added, ...}`. All three call a shared
  `assign_phase_state/1` helper so there is one source of truth for how to derive
  `usage_by_phase`, `phase_boundaries`, and `separator_targets`.
- **Phase 1 separator is always the top-of-list marker when the conversation has any
  items.** This matches the spec's "Phase 1's separator always renders at the top" —
  it is independent of whether phase 1 has `AI.Message` rows, because the separator
  exists to orient the reader, not to prove stats exist. Clickability and stats,
  however, still obey the "has AI.Message rows" rule.
- **Clickability condition (single definition):** a step is clickable iff its
  separator is rendered. The separator is rendered iff (phase == 1) or
  (`AI.Message` exists for phase N-1 in this AI session AND at least one JSONL entry
  has timestamp > that boundary). Stats are shown iff `AI.Message` exists for phase N
  in this AI session. These are independent conditions, so the stepper can show a
  step with stats but no separator (stats-only, non-clickable) and, conversely,
  render a separator for phase 1 even when phase 1 has no AI.Messages.
- **Carry `workflow_session` already in socket assigns — no extra fetch.** Stepper
  only needs `workflow_type` and `current_phase`, both present since mount.
- **CSS-only smooth scroll via Tailwind `scroll-smooth`.** Apply it to the existing
  `<div class="flex-1 min-h-0 overflow-y-auto">` scroll container. No JS hook,
  no scroll listeners; anchor clicks natively resolve to the nearest scroll
  ancestor.
- **`read_all/2` adapter unchanged.** The LiveView is the one place that cares about
  `"timestamp"`; parsing stays there so `Destila.AI.History` stays strictly an I/O
  adapter.

## Open Questions

### Resolved During Planning

- **Where do per-entry timestamps come from?** Resolved: `"timestamp"` key on raw JSONL
  entries returned by `Destila.AI.History.read_all/2`. Parsed to `DateTime` with
  `DateTime.from_iso8601/1`; non-parseable or missing values map to `nil` and those
  entries are excluded from wall-clock calculation.
- **How do bucketed entries handle a `nil` timestamp?** Resolved: they stay in the
  last known phase's bucket (the bucket before the failing entry) for rendering
  purposes, but do not contribute to wall-clock. This keeps separators placed
  correctly while avoiding silent NaN durations.
- **Does the separator for phase 1 need a matching `AI.Message`?** Resolved: no —
  phase 1 separator is always the first entry's marker. See Key Technical Decisions.
- **What structure do we pass into the new component?** Resolved: the stepper
  function component accepts `workflow_session`, `usage_by_phase` (map),
  `phase_wall_clocks` (map), and `clickable_phases` (MapSet or keyed map). Keeps
  the component pure.
- **Do we need to update the feature file's `Feature:` prose?** Resolved: yes — add a
  sentence stating the stepper/separators after the existing prose (the user prompt
  requires this).
- **Is there an existing test helper that seeds AI.Message rows with specific
  `inserted_at` values?** Resolved: `AI.create_message/2` autogenerates `inserted_at`
  via `{DateTime, :utc_now, []}`. The new tests write through it and then `Ecto.Repo.update_all/3`
  the `inserted_at` column to deterministic DateTimes (a pattern used in
  existing workflow tests).

### Deferred to Implementation

- Exact Tailwind classes for the active step (accent border, `bg-primary/10`, etc.)
  vs non-active (muted) — finalized during the visual pass.
- Whether the wall-clock label renders as `"1m 30s"` or `"90s"` — picked during
  implementation with a small helper consistent with `usage_totals_tooltip/1`.
- Behavior when `entry_times` contains mixed `nil` and present values: whether to
  surface a small "partial" indicator in the stepper — deferred; initial cut just
  computes wall-clock off non-nil entries only.
- Exact DOM layout of the stepper on narrow viewports — the header currently uses
  flex and the stepper fits to the right of the totals strip; if it becomes cramped,
  a small wrapping variant is chosen at implementation time.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not
> implementation specification. The implementing agent should treat it as context,
> not code to reproduce.*

**Data flow for a single mount/refresh:**

```
mount_with_session / refresh_history / handle_info({:message_added, ...})
  ↓
load_history(ai_session)                        # read_all returns raw entries w/ "timestamp"
  ↓                                             # normalize_entry drops into {:msg, %SessionMessage{}} or {:meta, raw}
  ↓                                             # new: parse_entry_timestamp → DateTime | nil (parallel list)
history_state = {:loaded, items, tool_index, entry_times}
  ↓
assign_phase_state(socket)
  ├─ AI.aggregate_usage_by_phase(ai_id)         # %{phase => totals_map}
  ├─ AI.phase_boundaries_for_ai_session(ai_id)  # %{phase => max_inserted_at}
  ├─ bucket_entries(items, entry_times, boundaries)
  │     → %{phase => {first_idx, first_ts, last_ts}}
  ├─ separator_targets(buckets)                 # %{first_idx => phase}
  └─ assign :usage_by_phase, :phase_buckets, :separator_targets
  ↓
render/1
  ├─ <.phase_stepper
  │    workflow_session=...
  │    usage_by_phase=...
  │    phase_wall_clocks=... (derived from phase_buckets)
  │    clickable_phases=... (keys of separator_targets)
  │  />
  └─ <.session_history
        items=merge_separators(items, separator_targets)
        tool_index=...
      />
```

**Stepper element shape (directional — not the final markup):**

```
#ai-session-phase-stepper
  └── for phase N in 1..total_phases:
        <a|span> id="phase-step-{N}" data-phase={N} data-active={bool}
          ├── <span>phase name</span>
          └── [if has stats]
                <span data-phase-turns>…</span>
                <span data-phase-in>…</span>
                <span data-phase-out>…</span>
                <span data-phase-cost>…</span>
                <span data-phase-duration>…</span>
                <span data-phase-wall>…</span>
```

Active styling goes on the step whose N matches `workflow_session.current_phase`.
`<a>` is used for clickable phases; `<span>` for empty phases. The `data-*`
attributes mirror the existing `data-totals-*` naming convention on the totals
strip.

**Separator element (directional):**

```
<div id="phase-separator-{N}" data-phase-separator={N} class="...">
  Phase {N} · {phase_name}
</div>
```

## Implementation Units

- [ ] **Unit 1: Add `AI.aggregate_usage_by_phase/1` and `AI.phase_boundaries_for_ai_session/1`**

**Goal:** Provide context-layer functions that group stored per-turn usage by
`Destila.AI.Message.phase` and expose the boundary timestamp (`max(inserted_at)`)
for each phase within a single AI session.

**Requirements:** R3, R9, R10, R11.

**Dependencies:** None.

**Files:**
- Modify: `lib/destila/ai.ex`
- Test: `test/destila/ai_test.exs` (create if absent — follow existing Destila
  context-test conventions under `test/destila/`)

**Approach:**
- Reuse `list_messages_for_ai_session/1` so ordering (`order_by: m.inserted_at`)
  and query shape stay consistent.
- `aggregate_usage_by_phase/1` groups by `msg.phase`, folding each group with the
  existing `add_message_usage/2` reducer so the returned map's values match the
  shape of `aggregate_usage_for_ai_session/1` (input_tokens, output_tokens,
  cache_read_input_tokens, cache_creation_input_tokens, total_cost_usd, duration_ms,
  turns). Zero-usage messages (no `"usage"` map) do not contribute, identical to
  existing behavior.
- `phase_boundaries_for_ai_session/1` returns `%{phase => %DateTime{}}` of the last
  `inserted_at` per phase. A single Ecto query (`group_by` + `max`) avoids loading
  all messages twice when called together with `aggregate_usage_by_phase/1`; if that
  micro-optimization is unclear, compute both from one in-memory pass over
  `list_messages_for_ai_session/1`.

**Patterns to follow:**
- `aggregate_usage_for_ai_session/1` and `empty_usage_totals/0` in
  `lib/destila/ai.ex` — mirror their shape and naming.

**Test scenarios:**
- Happy path: a session with messages in phases 1, 2, and 4 returns a map with
  keys `1, 2, 4` (no key for phase 3) and totals matching the summed usage per
  phase.
- Happy path: a session with no messages returns `%{}` from
  `aggregate_usage_by_phase/1` and `%{}` from `phase_boundaries_for_ai_session/1`.
- Edge case: a phase whose messages all lack a `"usage"` map returns `turns: 0` and
  zeroed counters for that phase (matches `aggregate_usage_for_ai_session/1`
  behavior).
- Edge case: `phase_boundaries_for_ai_session/1` returns a strictly-increasing
  `inserted_at` when messages are seeded with monotonically increasing timestamps,
  proving the boundary is genuinely the `max` per phase.
- Integration: values in `aggregate_usage_by_phase/1` summed across phases equal
  `aggregate_usage_for_ai_session/1` (modulo map shape), proving the per-phase
  grouping does not drop turns.

**Verification:**
- New tests green.
- `aggregate_usage_for_ai_session/1` behavior is unchanged (regression guard by
  running existing `usage totals strip` tests).

- [ ] **Unit 2: Add `phase_stepper/1` function component and separator branch in `session_item/1`**

**Goal:** Add a pure render layer that produces the stepper markup (DOM ids,
`data-*` attributes, active/empty styling, anchor href vs span) and lets the
existing `session_history/1` interleave phase-separator dividers inside the
transcript.

**Requirements:** R1, R2, R3, R4, R5, R6, R7, R13.

**Dependencies:** Unit 1 (shape of `usage_by_phase` map).

**Files:**
- Modify: `lib/destila_web/components/ai_session_debug_components.ex`
- Test: covered by Unit 4 LiveView tests — no component-level test file added (the
  module has no standalone tests today and the rendered output is exercised via the
  LiveView).

**Approach:**
- Add `phase_stepper/1` accepting:
  - `workflow_session` (for `workflow_type`, `current_phase`),
  - `usage_by_phase` (`%{phase_num => totals_map}`),
  - `phase_wall_clocks` (`%{phase_num => duration_ms_integer}`),
  - `clickable_phases` (`MapSet.t()` of phase numbers).
- Iterate `1..Workflows.total_phases(workflow_type)`. For each N:
  - Lookup `phase_name = Workflows.phase_name(workflow_type, N)`.
  - Render wrapper `<a>` when `N in clickable_phases`, else `<span>`; apply
    stable id `phase-step-{N}`, `data-phase={N}`, `data-active={N == current_phase}`.
  - When `Map.has_key?(usage_by_phase, N)`, render inner stat spans
    (`data-phase-turns`, `data-phase-in`, `data-phase-out`, `data-phase-cost`,
    `data-phase-duration`, `data-phase-wall`); otherwise render only the name.
- Extend `session_item/1` with a new pattern for `{:separator, phase_num, phase_name}`
  that emits `<div id="phase-separator-{phase_num}" data-phase-separator=...>`.
- Add a formatting helper for wall-clock (duration in ms → `"90s"` / `"1m 30s"`);
  keep consistent with `usage_totals_tooltip/1` style.
- No changes to existing `session_item/1` branches, no changes to
  `session_history/1`'s outer iteration.

**Patterns to follow:**
- `usage_totals_strip/1` in `lib/destila_web/live/ai_session_detail_live.ex` for
  `data-*` attribute shape and `format_cost/1` reuse.
- `meta_entry/1` branches (line 125 in components) for divider markup style —
  the compact-boundary divider is the closest visual analog.

**Test scenarios:**
- Delegated to Unit 4 (tests drive the rendered output through the LiveView).

**Verification:**
- Module compiles (`mix compile`).
- No `Phoenix.Component.attr/3` declarations without matching attribute access.
- Existing component tests — exercised via existing LiveView test suite — continue
  to pass.

- [ ] **Unit 3: Preserve JSONL entry timestamps, compute phase buckets and assigns in `AiSessionDetailLive`, wire stepper + separators into render**

**Goal:** Plumb per-entry timestamps through `history_state`, compute phase buckets
and wall-clocks server-side once per refresh, assign the derived state on the socket,
render the stepper in the header, and merge separator pseudo-items into the items
list passed to `session_history/1`. Apply `scroll-smooth` to the scroll container.

**Requirements:** R1, R4, R6, R7, R8, R9, R10, R11, R12, R13.

**Dependencies:** Units 1 and 2.

**Files:**
- Modify: `lib/destila_web/live/ai_session_detail_live.ex`
- Test: covered by Unit 4.

**Approach:**
- Change `history_state` loaded tuple from `{:loaded, items, tool_index}` to
  `{:loaded, items, tool_index, entry_times}` where `entry_times` is a list of
  `DateTime.t() | nil`, same length as `items`, derived before `normalize_entry/1`
  by peeking at the raw entry's `"timestamp"`. Update `load_history/1`,
  `append_entries/2`, and `refresh_history/1` accordingly.
- Add a private `parse_entry_timestamp/1` helper using `DateTime.from_iso8601/1`.
- Introduce `assign_phase_state/1` on the socket that computes:
  - `usage_by_phase = AI.aggregate_usage_by_phase(ai_session_id)`,
  - `boundaries = AI.phase_boundaries_for_ai_session(ai_session_id)`,
  - `phase_buckets` via in-memory iteration over `items` + `entry_times`:
    - start phase counter at 1,
    - whenever the current entry's timestamp exceeds `boundaries[current]`, advance
      the counter to the smallest phase whose predecessor boundary is exceeded,
    - record the first item index of each phase, and update first_ts/last_ts,
  - `separator_targets` (map `%{item_idx => phase_num}`):
    - phase 1 always maps to item index 0 when items is non-empty,
    - phase N > 1 maps to the first item index assigned to phase N only if
      `Map.has_key?(boundaries, N-1)` (otherwise omitted so the separator is not
      rendered, per R10),
  - `phase_wall_clocks = %{phase => DateTime.diff(last_ts, first_ts, :millisecond)}`
    computed only for phases that have at least two non-nil timestamps in their
    bucket,
  - `clickable_phases = separator_targets |> Map.values() |> MapSet.new()`.
- Call `assign_phase_state/1` in:
  - `mount_with_session/3` (after the existing `assign(:usage_totals, ...)`),
  - `refresh_history/1` (after `assign :history_state`),
  - `handle_info({:message_added, _}, socket)` (after `assign(:usage_totals, ...)`).
- In `render/1`:
  - Insert `<.phase_stepper ... />` inside the header block, immediately after the
    `<.usage_totals_strip .../>` call, wrapped in its own row so it sits above the
    scroll container per the spec's "in the page header (above the conversation
    container)". Wrap the header in two stacked rows if layout demands it; preserve
    all existing header elements (back link, aliveness dot, cpu chip, title,
    timestamp, claude_session_id, usage_totals_strip).
  - Change the outer scroll container's class list to include `scroll-smooth`.
  - Inside the `{:loaded, ...}` branch, build a `rendered_items` list by folding
    `separator_targets` into `items` (inserting `{:separator, phase, phase_name}`
    at the recorded indices), then pass `rendered_items` as `items` to
    `session_history`.
- Update the `{:loaded, items, tool_index}` match to the new 4-tuple everywhere.

**Execution note:** Start from the existing `usage_totals_strip` integration tests as
characterization: they provide the safety net for header markup. Run them before
and after to confirm no regression.

**Patterns to follow:**
- `refresh_history/1` (line 118) and `maybe_schedule_reload/1` (line 104) — keep
  their control flow; only the shape of `history_state` changes.
- The existing `{:message_added, _}` branch (line 94) — assign both `usage_totals`
  and the new phase-state in the same block so the refresh cadence stays atomic.

**Test scenarios:**
- Delegated to Unit 4 (tests drive stepper markup and separator placement through
  the LiveView).

**Verification:**
- `history_state` 4-tuple match compiles cleanly with no stray 3-tuple matches
  (`mix compile --warnings-as-errors`).
- Existing history live-update tests still green (reload does not duplicate
  messages, empty → loaded transition, etc.).

- [ ] **Unit 4: Extend feature file and LiveView tests**

**Goal:** Add the 8 new Gherkin scenarios and LiveView tests covering every
behavioral requirement. Ensure every new scenario is linked to a test and no
existing scenario loses its linked test.

**Requirements:** R14, R15, plus regression coverage for R1–R13.

**Dependencies:** Units 1–3.

**Files:**
- Modify: `features/ai_session_detail.feature`
- Modify: `test/destila_web/live/ai_session_detail_live_test.exs`

**Approach:**
- Extend the `Feature:` prose at the top of `features/ai_session_detail.feature`
  with a short sentence naming the stepper + separators.
- Append the 8 new scenarios verbatim from the user prompt:
  1. Phase stepper lists all workflow phases in order
  2. Current workflow phase is highlighted in the stepper
  3. Phase step shows per-phase aggregated stats
  4. Empty phase step renders without stats and is not clickable
  5. Phase separator divider precedes the first message of each phase
  6. Clicking a non-empty phase step scrolls to its separator
  7. Phase stepper updates live when new turns are recorded
  8. Wall-clock time spans first to last message of the phase
- Add a new `describe "phase stepper"` block to the test file with:
  - A fixture helper `insert_phase_message/4` that inserts an `AI.Message` with a
    specific `:phase` and (optionally) deterministic `inserted_at` (via `Repo.update_all`
    on the row after insert, following the pattern used in existing workflow tests
    that need controlled timestamps).
  - A fixture helper `raw_entry/3` to build raw JSONL map entries with a given ISO
    `"timestamp"`, used with `FakeHistory.stub_raw/2`.
- Each test targets the scenario by DOM id/selectors, per the "always assert on
  DOM IDs" guideline. Representative selectors:
  - Stepper presence: `#ai-session-phase-stepper`
  - Every phase step: `#phase-step-1`, `#phase-step-2`, ... up to `total_phases`
  - Active step: `[data-phase="2"][data-active="true"]`
  - Stats cells: `[data-phase-turns]`, `[data-phase-in]`, etc.
  - Separators: `#phase-separator-1`, `#phase-separator-2`, ...
  - Anchor wiring: `a#phase-step-2[href="#phase-separator-2"]`
  - Empty step non-clickability: `span#phase-step-3` (no `a` element) and absence
    of `[data-phase-turns]` inside it.
- Live refresh test: open the view with no phase-2 messages, then call
  `insert_system_message_with_usage/3` with a raw that includes `phase: 2`
  metadata (or directly insert via `AI.create_message/2` with `phase: 2`) and
  assert the stepper updates via the existing `{:message_added, _}` path without
  `send(view.pid, :reload_history)`.
- Wall-clock test: seed two raw JSONL entries 90s apart, both after a phase-1
  boundary, stub the history, assert `#phase-step-2 [data-phase-wall]` contains
  `"90s"` (or `"1m 30s"` depending on the formatter chosen in Unit 2; the test
  should assert the actual label shape produced).

**Patterns to follow:**
- Existing `describe "usage totals strip"` block — fixture helpers
  `insert_system_message_with_usage/3`, `usage_raw/3`; the phase block mirrors
  this shape.
- Existing tests use `FakeHistory.stub/2` for `%SessionMessage{}` lists and
  `FakeHistory.stub_raw/2` for raw JSONL maps; both are already wired through the
  `Destila.AI.History` adapter and require no new setup.

**Test scenarios:**
- Happy path: stepper renders exactly `total_phases` steps for the session's
  workflow type, each with `id="phase-step-N"` and the matching phase name.
- Happy path: the step whose `N == workflow_session.current_phase` has
  `data-active="true"`; all others have `data-active="false"`.
- Happy path: for a phase with `AI.Message` rows, `data-phase-turns`,
  `data-phase-in`, `data-phase-out`, `data-phase-cost`, `data-phase-duration`
  carry values derived from `aggregate_usage_by_phase/1`.
- Edge case: for a phase with no `AI.Message` rows, the step is a `<span>` (not an
  `<a>`), has no `data-phase-turns`/etc., and no matching `#phase-separator-N` is
  rendered.
- Edge case: with zero `AI.Message` rows and any number of JSONL entries, only
  `#phase-separator-1` renders at the top; higher phases are all empty.
- Integration: separator `#phase-separator-N` appears before the first
  `[data-message-role]` whose underlying JSONL entry is in phase N's bucket, and
  after the last entry of phase N-1.
- Integration: clicking (i.e., asserting href) `#phase-step-2` targets
  `#phase-separator-2`.
- Integration: container element has the `scroll-smooth` Tailwind class.
- Integration (live): after `AI.create_message(ai.id, %{phase: 2, raw_response: ...})`
  broadcasts, the stepper updates without calling `send(view.pid, :reload_history)`.
- Wall-clock: seed entries such that phase 2 spans 90 seconds; assert
  `#phase-step-2 [data-phase-wall]` text matches the formatter's output.

**Verification:**
- `mix test test/destila_web/live/ai_session_detail_live_test.exs` is green.
- `mix test --only feature:ai_session_detail` is green.
- Existing scenarios still pass (no orphaned `@tag` references).
- `mix precommit` is green.

## System-Wide Impact

- **Interaction graph:**
  - `Destila.AI` context gains two new pure functions that may later be reused by
    other LiveViews (e.g. the AI sessions sidebar) — no callers are added in this
    plan.
  - `AiSessionDetailLive` remains the only call site for these functions.
  - `AiSessionDebugComponents` gains a new function component; no other module
    depends on it.
  - `workflow_session.current_phase` read-only dependency; no writes.
- **Error propagation:**
  - Timestamp parse failures (`DateTime.from_iso8601/1 :error`) degrade to `nil`
    and those entries silently drop out of wall-clock computation. They stay in
    their last-known-bucket for rendering purposes so a separator is not accidentally
    placed before them.
  - `AI.aggregate_usage_by_phase/1` tolerates messages without `raw_response` the
    same way `aggregate_usage_for_ai_session/1` does.
- **State lifecycle risks:**
  - `refresh_history/1` must recompute phase state when items grow — missing this
    is the common failure mode. The shared `assign_phase_state/1` helper mitigates
    by funneling all three refresh sites through one code path.
  - Debounced reload must not double-insert separators; since separator placement
    is derived from indices after the full items list is rebuilt, idempotency
    is guaranteed by construction.
- **API surface parity:**
  - Stepper DOM ids (`#ai-session-phase-stepper`, `#phase-step-N`, `#phase-separator-N`)
    form the testable contract. Keep them stable.
- **Integration coverage:**
  - LiveView tests must assert both (a) the stepper matches the workflow's phases,
    and (b) clicking wiring: the anchor href on `#phase-step-N` matches the id of
    `#phase-separator-N`. Asserting only presence of both elements is not enough.
- **Unchanged invariants:**
  - `usage_totals_strip/1` and its `#ai-session-usage-totals` tests keep working.
  - `aliveness_dot`, `session_history/1`, `meta_entry/1` branches, `empty_state/1`
    are all untouched.
  - `{:ai_stream_chunk, _}` debounce timing (`@reload_debounce_ms = 500`) is
    unchanged.
  - PubSub subscriptions list on mount is unchanged.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `history_state` 4-tuple match misses a call site and crashes a hot path | Single grep pass for `{:loaded,` across `lib/destila_web/live/ai_session_detail_live.ex`; `mix compile --warnings-as-errors` to surface stragglers. |
| Phase bucket assignment drifts when timestamps are missing | `parse_entry_timestamp/1` returns `nil`; bucket counter only advances when the timestamp is present and exceeds the boundary; `nil` entries inherit the prior bucket. |
| Test fixtures make assumptions about `AI.create_message/2` auto-timestamps that do not hold | Tests explicitly override `inserted_at` via `Repo.update_all` on inserted rows; this is already a known pattern in the Destila test suite. |
| `scroll-behavior: smooth` does not animate because the header consumes the anchor | The scroll container (inner, `overflow-y-auto`) is the native scroll ancestor for the anchor target; applying `scroll-smooth` there is sufficient. Verified by reviewing the DOM structure around line 248. |
| Broken existing feature test due to Feature prose edit | Only append sentences; never delete or reorder existing scenarios. Run full feature tag before committing: `mix test --only feature:ai_session_detail`. |

## Documentation / Operational Notes

- No user-facing docs updates required; this is an internal debug tool.
- No monitoring / rollout concerns; the feature is read-only.
- No feature flag — the page already exists and the new stepper is strictly additive.

## Sources & References

- Feature file: `features/ai_session_detail.feature`
- LiveView under edit: `lib/destila_web/live/ai_session_detail_live.ex`
- Context under edit: `lib/destila/ai.ex`
- Component under edit: `lib/destila_web/components/ai_session_debug_components.ex`
- Test file under edit: `test/destila_web/live/ai_session_detail_live_test.exs`
- Related plan (prior art for this page): `docs/plans/2026-04-16-001-feat-ai-sessions-sidebar-and-debug-detail-plan.md`
- Related modules: `Destila.Workflows` (`lib/destila/workflows.ex`), `Destila.Workflows.Workflow` (`lib/destila/workflows/workflow.ex`), `Destila.AI.Message` (`lib/destila/ai/message.ex`), `ClaudeCode.History.SessionMessage` (`deps/claude_code/lib/claude_code/history/session_message.ex`)
