---
title: "feat: Surface RateLimitEvent as transient chat chips"
type: feat
status: completed
date: 2026-04-20
---

# Surface RateLimitEvent as Transient Chat Chips

## Overview

Render `%ClaudeCode.Message.RateLimitEvent{}` chunks that flow through the
AI stream as ephemeral, non-persisted chips in the workflow runner chat
timeline during the `:processing` phase. Each event appears as its own chip
with a visual variant keyed off `status` (`:allowed`, `:allowed_warning`,
`:rejected`), displays the rate limit type, utilization percentage, a
relative reset time (with absolute time in a `title` tooltip), and an
overage indicator when `is_using_overage` is true. When the turn completes
(phase status leaves `:processing`) the chips are cleared alongside the
existing intermediate text bubbles by the existing clearing logic. No
backend changes, no persistence, no reloads ever show historical chips.

## Problem Frame

`Destila.AI.ClaudeSession.collect_with_mcp_and_broadcast/2` already
broadcasts every stream item — including `RateLimitEvent` messages — over
the workflow-session stream topic as `{:ai_stream_chunk, item}`. The
LiveView currently drops anything that is not an `AssistantMessage` with
text or a `ResultMessage` with a non-empty `result` (see
`lib/destila_web/live/workflow_runner_live.ex:566-580`). As a result,
users get no visibility into the AI's rate-limit state — including the
`:allowed_warning` and `:rejected` cases that matter most. We need to
surface these events live without introducing persistence or widening the
feature beyond the chat timeline.

## Requirements Trace

- R1. `%ClaudeCode.Message.RateLimitEvent{}` chunks arriving during
  `:processing` append a new entry to the existing `:intermediate_bubbles`
  assign (interleaved with text bubbles in arrival order)
- R2. The chip displays: status variant, `rate_limit_type`, `utilization`
  as a percentage, relative reset time, and overage indicator when
  `is_using_overage` is true
- R3. Three known statuses (`:allowed`, `:allowed_warning`, `:rejected`)
  each render with a distinct visual variant (informational / warning /
  error). Unknown status strings fall back to a safe neutral variant
- R4. `resets_at` renders as a human-friendly relative time
  (e.g. "resets in 2h 15m") with the absolute local time in a
  `title`/tooltip attribute
- R5. Each `RateLimitEvent` during a turn renders as its own chip — no
  collapsing — in the order received
- R6. Chips are cleared when `phase_status` transitions out of
  `:processing`, using the existing clearing logic in
  `handle_info({:workflow_session_updated, _}, socket)` (no parallel
  clearing path)
- R7. Missing optional fields (`resets_at`, `utilization`,
  `overage_*`, `surpassed_threshold`) render gracefully as partial info
  rather than crash
- R8. Events are never persisted (no DB writes, no history broadcast, no
  rendering in `AiSessionDetailLive`); reload shows no chip history
- R9. Gherkin scenarios in `features/brainstorm_idea_workflow.feature`
  are updated under `# --- Streaming Message Bubbles ---` and every new
  test carries a `@tag feature:/scenario:` pair linking to them
- R10. `mix precommit` passes before finishing

## Scope Boundaries

- **No backend changes** — `ClaudeSession.collect_with_mcp_and_broadcast/2`
  already broadcasts every stream item; we only consume what is there.
- **No rendering in the AI Session Debug Detail page**
  (`AiSessionDetailLive`) — chips remain live-only in the workflow runner
  chat.
- **No persistence** — no Ecto writes, no `%Destila.AI.Message{}` rows,
  no broadcasts on the persisted-message topic.
- **No accumulation/collapsing of repeated events** — multiple chips
  appear during a single turn, each for its own event.
- **No new throttling or debouncing** — matches the prior streaming
  pattern.
- **No structural changes to `chat_phase/1`'s `phase-section` layout** —
  chips render inside the existing `phase == @phase_number && @phase_status == :processing`
  branches, right where `chat_intermediate_bubble` already renders.
- **Not surfaced in the `chat_stream_debug` branch** — that debug view is
  only visible when `@streaming_chunks` is non-empty and is scoped to
  developer debugging, not user-facing rate-limit signalling. Adding
  anything there risks cross-coupling the two code paths.

## Context & Research

### Relevant Code and Patterns

- `lib/destila/ai/claude_session.ex:249-324` —
  `collect_with_mcp_and_broadcast/2` already broadcasts every stream
  item, including `RateLimitEvent`, via
  `Phoenix.PubSub.broadcast(Destila.PubSub, topic, {:ai_stream_chunk, item})`.
  No backend modification required.
- `lib/destila_web/live/workflow_runner_live.ex:507-524` —
  `handle_info({:ai_stream_chunk, chunk}, socket)` currently calls
  `extract_intermediate_text/1` and only appends `%{text: text}` maps
  when a text chunk arrives. This is the extension point for
  `RateLimitEvent`.
- `lib/destila_web/live/workflow_runner_live.ex:566-580` —
  `extract_intermediate_text/1` has fallthrough clauses; the new
  `RateLimitEvent` branch belongs next to them, and its entry map
  gets tagged with `:type`.
- `lib/destila_web/live/workflow_runner_live.ex:481-487` — existing
  clearing logic already resets `:intermediate_bubbles` to `[]` whenever
  `phase_status != :processing`. This is re-used; **no new clearing
  path is added**.
- `lib/destila_web/components/chat_components.ex:86-96, 113-123` — both
  `phase-section` branches iterate `@intermediate_bubbles` and call
  `chat_intermediate_bubble`. This is where the `:type` discriminator is
  consumed and a new sibling component handles rate-limit entries.
- `lib/destila_web/components/chat_components.ex:702-715` —
  `chat_intermediate_bubble/1` is the styling reference: dashed border,
  Tailwind utility classes, left-aligned system-bubble layout. The new
  component follows the same layout conventions (class lists, no
  `@apply`, no inline `<script>`).
- `deps/claude_code/lib/claude_code/message/rate_limit_event.ex` — event
  shape: `:rate_limit_info` map with `:status` (atom), `:resets_at` (ms
  unix timestamp | nil), `:utilization` (0.0–1.0 | nil), `:rate_limit_type`
  (string | nil), `:overage_status`, `:overage_resets_at`,
  `:overage_disabled_reason`, `:is_using_overage`, `:surpassed_threshold`.
  **`parse_status/1` passes unknown strings through unchanged**
  (`defp parse_status(other), do: other`), so the rendering code must
  not pattern-match exhaustively.
- `test/destila_web/live/brainstorm_idea_workflow_live_test.exs:583-744` —
  existing `describe "Streaming intermediate bubbles"` block. New tests
  mirror its pattern: `create_session_in_phase(1, pe_status: :processing)`,
  `Destila.PubSubHelper.ai_stream_topic/1`, `Phoenix.PubSub.broadcast` with
  `{:ai_stream_chunk, chunk}`, then `has_element?/2` or `render/1`
  assertions. The clearing test at lines 694-718 shows the phase-exit
  pattern to copy for the "cleared on turn completion" scenario.
- `features/brainstorm_idea_workflow.feature` — the `# --- Streaming Message Bubbles ---`
  section already exists; new scenarios append there.

### Institutional Learnings

- The streaming intermediate bubbles plan
  (`docs/plans/2026-04-15-001-feat-streaming-intermediate-bubbles-plan.md`)
  established that ephemeral UI lives in a plain list assign (not a
  LiveView stream) cleared on phase exit, and that each chunk = one
  bubble (no accumulation). This plan inherits both decisions.
- The same plan documented that no PubSub throttling was added and that
  `ScrollBottom` hook auto-scrolls on re-render via its `updated()`
  callback — which handles the new chips for free.

### External References

- Not needed. The work is confined to LiveView and HEEx patterns already
  well-established in this codebase.

## Key Technical Decisions

- **Single `:intermediate_bubbles` assign with a `:type` discriminator**:
  Rate-limit chips interleave with text bubbles in arrival order. A
  uniform shape (`%{type: :text, text: ...}` / `%{type: :rate_limit, event: ...}`)
  preserves ordering, keeps the existing clearing logic in one place,
  and needs only a single `:for` loop in the template. Matches the
  explicit guidance in the user request.
- **Store the whole `RateLimitEvent` struct in the entry, not a
  pre-formatted map**: Relative reset time depends on the render-time
  clock. Keeping the raw event lets the component compute the relative
  string at render time, keeps the helper pure, and avoids stale
  values when LiveView re-renders.
- **New sibling component `chat_rate_limit_chip/1`** next to
  `chat_intermediate_bubble/1` rather than a multi-mode component.
  Smaller surface, clearer visual contract, easier to test.
- **Status-to-variant mapping is a small pure helper** (likely
  `rate_limit_variant/1`) with four cases — `:allowed`, `:allowed_warning`,
  `:rejected`, and a catch-all neutral fallback. The catch-all protects
  against the `parse_status/1` pass-through behavior for unknown strings.
- **Reuse existing clearing logic**: Do **not** add a second place that
  resets `:intermediate_bubbles`. The `handle_info({:workflow_session_updated, _}, socket)`
  clause at `workflow_runner_live.ex:481-487` already sets it to `[]`
  on any phase_status change out of `:processing`. Adding a parallel
  path would create drift risk.
- **Relative-time formatting helper lives in `ChatComponents`** (not
  LiveView) because it is a render-time concern. Pure function: takes
  `resets_at` (ms unix or nil) and a "now" DateTime, returns a string
  (or `nil`). Testable in isolation; injectable `now` parameter for
  deterministic tests.
- **Stable DOM IDs on each chip** (e.g. `id={"rate-limit-chip-#{index}"}`
  on the entry index, or a per-entry UUID) so LiveView tests can use
  `has_element?/2` against a stable selector without scraping markup.
  Prefer a stable selector like `[data-test="rate-limit-chip"]` plus a
  `data-status` attribute to make status-variant assertions cleanly
  expressible (`has_element?(view, "[data-test=rate-limit-chip][data-status=rejected]")`).

## Open Questions

### Resolved During Planning

- **Where does the chip render in the phase section?** — Inside the same
  two `phase == @phase_number && @phase_status == :processing` branches
  where `chat_intermediate_bubble` already renders, replacing the flat
  `:for={bubble <- @intermediate_bubbles}` call with a branch on
  `bubble.type`.
- **Do we need a new PubSub topic or broadcast?** — No. The existing
  `ai_stream_topic/1` already carries every stream item.
- **Do we render chips in `AiSessionDetailLive`?** — No. Explicit scope
  boundary: chat timeline only.
- **What do we do with unknown status strings?** — Render with a neutral
  fallback variant. The upstream `parse_status/1` passes unknown strings
  through verbatim, so we must not exhaustively pattern-match.
- **Is there any risk of double-rendering the same event on re-mount?** —
  No. `:intermediate_bubbles` is socket-local and not persisted; a fresh
  mount starts with `[]` (see `workflow_runner_live.ex:69`).

### Deferred to Implementation

- **Exact Tailwind color classes per variant** — the plan specifies
  informational / warning / error semantics; the exact color tokens
  (e.g. `bg-info/10 text-info` vs. `bg-warning/10 text-warning`) are
  an implementation detail that the implementer can pick to fit the
  existing chat palette.
- **Exact relative-time granularity** — "resets in 2h 15m" is the target
  shape; whether to round to the nearest minute, drop seconds below a
  minute, or say "resets soon" when under 1 minute is a formatting
  detail left to the implementer. Keep the helper pure and testable.
- **Whether overage fields warrant a secondary sub-line or a small
  badge** inside the chip — decided at implementation time based on how
  crowded the chip feels in practice.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

Data flow, with the only changed surfaces highlighted:

```
ClaudeCode stream
      │
      ▼
Destila.AI.ClaudeSession.collect_with_mcp_and_broadcast/2   (unchanged)
  broadcasts {:ai_stream_chunk, item} on ai_stream_topic(ws_id)
      │
      ▼
DestilaWeb.WorkflowRunnerLive.handle_info({:ai_stream_chunk, chunk}, socket)
  ├── %AssistantMessage{} with text  → %{type: :text, text: t}      (existing)
  ├── %ResultMessage{result: binary} → %{type: :text, text: r}      (existing)
  ├── %RateLimitEvent{} = event      → %{type: :rate_limit, event: event}   (NEW)
  └── everything else                → :skip                        (existing)
       │
       └─► append to socket.assigns.intermediate_bubbles (single list, interleaved)
      │
      ▼
handle_info({:workflow_session_updated, _}, socket)        (unchanged)
  if phase_status != :processing → intermediate_bubbles = []  ← clears chips too
      │
      ▼
DestilaWeb.ChatComponents.chat_phase/1
  :for={bubble <- @intermediate_bubbles}
    case bubble.type do
      :text        → <.chat_intermediate_bubble text={...} />   (existing)
      :rate_limit  → <.chat_rate_limit_chip event={bubble.event} />  (NEW)
    end
```

Entry map shapes (uniform with a `:type` discriminator):

```
%{type: :text,       text: String.t()}
%{type: :rate_limit, event: %ClaudeCode.Message.RateLimitEvent{}}
```

Rendered chip anatomy (illustrative, not final markup):

```
┌──────────────────────────────────────────────────────────────┐
│ ⚠  five_hour · 85%                   resets in 2h 15m   🔥  │
│    (warning variant — bg-warning/10, text-warning)            │
│    title="Resets at 14:32 local"                              │
│    🔥 = is_using_overage indicator                            │
└──────────────────────────────────────────────────────────────┘
```

Status → variant decision table:

| Status              | Visual variant  | Semantic                          |
|---------------------|-----------------|-----------------------------------|
| `:allowed`          | informational   | neutral/info palette              |
| `:allowed_warning`  | warning         | warning palette                   |
| `:rejected`         | error           | error/alert palette               |
| *anything else*     | neutral         | safe fallback (no crash)          |

## Implementation Units

- [ ] **Unit 1: Extend `:intermediate_bubbles` shape with `:type` discriminator**

**Goal:** Change the LiveView to append tagged entries to
`:intermediate_bubbles` and recognize `%ClaudeCode.Message.RateLimitEvent{}`
chunks alongside the existing text producers.

**Requirements:** R1, R5, R7

**Dependencies:** None

**Files:**
- Modify: `lib/destila_web/live/workflow_runner_live.ex`
- Test: `test/destila_web/live/brainstorm_idea_workflow_live_test.exs`

**Approach:**
- Change the existing text producers
  (`extract_intermediate_text/1` clauses around lines 566-580) so they
  return tagged entries of the shape
  `{:ok, %{type: :text, text: binary}}`, or rename the helper to
  `extract_intermediate_entry/1` — whichever keeps
  `handle_info({:ai_stream_chunk, chunk}, socket)` readable.
- Add a new clause that matches `%ClaudeCode.Message.RateLimitEvent{} = event`
  and returns `{:ok, %{type: :rate_limit, event: event}}`.
- Keep the `:skip` fallthrough clause unchanged.
- In `handle_info({:ai_stream_chunk, chunk}, socket)` at lines 507-524,
  append the returned entry verbatim to `:intermediate_bubbles` so
  insertion order is preserved across text and rate-limit chunks.
- **Do NOT** add a second clearing path. The existing
  `handle_info({:workflow_session_updated, _}, socket)` clause at lines
  481-487 already resets the list to `[]` whenever `phase_status`
  changes out of `:processing` — it will now clear both text bubbles
  and rate-limit entries with no change.

**Patterns to follow:**
- Existing `extract_intermediate_text/1` clause style
  (`workflow_runner_live.ex:566-580`)
- Existing append-and-reassign pattern in the `:ai_stream_chunk` handler

**Test scenarios:**
- *Happy path*: broadcasting a `%ClaudeCode.Message.RateLimitEvent{}` on
  `ai_stream_topic/1` during `:processing` causes the
  `:intermediate_bubbles` assign to contain a `%{type: :rate_limit, ...}`
  entry in arrival order. Assert via rendered DOM (stable selector —
  see Unit 2) rather than poking socket state.
- *Happy path*: broadcasting text-producing chunks and a `RateLimitEvent`
  in sequence produces a single list whose order matches the broadcast
  order (text, rate-limit, text → text bubble, chip, text bubble
  visible in that order in the rendered HTML).
- *Edge case*: a `RateLimitEvent` whose `rate_limit_info` contains
  `nil` for `resets_at`, `utilization`, `rate_limit_type`, and
  `is_using_overage` does not crash the `handle_info` callback and
  reaches the template.
- *Edge case*: an unknown status string (e.g. `"throttled"`) inside
  `rate_limit_info.status` is accepted by the `handle_info` path
  (the upstream parser passes it through verbatim).

**Verification:**
- The assign contains tagged entries in broadcast order
- Text bubbles and rate-limit entries interleave correctly
- No new clearing code was added; the existing `:workflow_session_updated`
  path alone sweeps both types on phase exit
- `mix compile --warnings-as-errors` passes

---

- [ ] **Unit 2: Add `chat_rate_limit_chip/1` component and render helpers**

**Goal:** Render rate-limit entries as visually distinct chips with
per-status variants, relative reset time, overage indicator, and stable
DOM identity, alongside existing text bubbles.

**Requirements:** R2, R3, R4, R5, R7

**Dependencies:** Unit 1 (entries with `:type` discriminator must exist)

**Files:**
- Modify: `lib/destila_web/components/chat_components.ex`
- Test: `test/destila_web/live/brainstorm_idea_workflow_live_test.exs`

**Approach:**
- In `chat_phase/1`, replace the two identical
  `<.chat_intermediate_bubble :for={bubble <- @intermediate_bubbles} ... />`
  calls (lines 86-90 and 113-117) with a branch on `bubble.type`:
  - `:text` → existing `<.chat_intermediate_bubble text={bubble.text} />`
  - `:rate_limit` → new `<.chat_rate_limit_chip event={bubble.event} />`
  - unknown `:type` values should fall back to rendering nothing (defensive;
    keeps future additions from breaking the template).
- Add `chat_rate_limit_chip/1` next to `chat_intermediate_bubble/1`
  (around line 700). Layout: same left-aligned-system-bubble frame
  (avatar + rounded container), but with a chip-style compact body and
  per-status color variant.
- Add a private `rate_limit_variant/1` helper that maps
  `:allowed` / `:allowed_warning` / `:rejected` / _ to a variant atom
  (e.g. `:info`, `:warning`, `:error`, `:neutral`). Use the variant in
  a class list to pick Tailwind color utilities.
- Add a private pure helper `format_reset_time/2` (takes `resets_at` in
  ms unix or `nil`, and a `now` DateTime) returning `{relative, absolute}`
  strings or `{nil, nil}` when `resets_at` is missing. Use `DateTime`
  and `Time`/`Calendar` from the standard library (per CLAUDE.md
  guidelines); no new dependencies.
- The chip must tolerate `nil` `rate_limit_type`, `utilization`,
  `is_using_overage`, and `resets_at` — render only the pieces that
  exist.
- Add a stable test hook: `data-test="rate-limit-chip"` plus
  `data-status={to_string(event.rate_limit_info.status)}` on the outer
  container, with a unique `id` per chip for LiveView diffing.
- Place `title={absolute_time_string}` on the relative-time span.
- Keep all styling in Tailwind utility class lists; **no `@apply`**,
  **no inline `<script>`**, **no daisyUI** — per CLAUDE.md guidelines.

**Patterns to follow:**
- `chat_intermediate_bubble/1` at `chat_components.ex:702-715` — layout,
  class-list style, `rounded-2xl px-4 py-3` bubble shape.
- System message bubble styling referenced in the prior streaming plan
  for color/tone consistency.
- HEEx class-list guidance from CLAUDE.md: use `class={[...]}`
  with parenthesised `if/else` expressions for conditional classes.

**Test scenarios:**
- *Happy path — `:allowed_warning` variant*: broadcast a `RateLimitEvent`
  with status `:allowed_warning`, `rate_limit_type: "five_hour"`,
  `utilization: 0.85`, `resets_at` a few minutes in the future,
  `is_using_overage: false`. Assert a chip is visible
  (`has_element?(view, "[data-test=rate-limit-chip][data-status=allowed_warning]")`)
  and that the rendered HTML contains "five_hour", "85%", and an
  `href`/`title` attribute carrying the absolute time.
- *Happy path — `:rejected` variant*: broadcast with status `:rejected`.
  Assert a chip with `data-status=rejected` is present and rendered
  with the error-variant classes (assert via class substring present
  in the rendered HTML — e.g., a stable class token distinct from the
  warning variant).
- *Happy path — `:allowed` variant*: broadcast with status `:allowed`.
  Assert a chip with `data-status=allowed` is present and rendered
  with the informational-variant classes.
- *Edge case — unknown status*: broadcast with status `"throttled"`
  (a bare string that the upstream parser passes through). Assert a
  chip is still rendered with a neutral fallback variant (e.g.,
  `data-status=throttled`, no crash).
- *Edge case — missing optional fields*: broadcast with
  `resets_at: nil`, `utilization: nil`, `rate_limit_type: nil`,
  `is_using_overage: nil`. Assert the chip renders without crashing
  and does not include spurious "%", "resets in", or overage-indicator
  markers for absent fields.
- *Edge case — overage indicator*: broadcast with `is_using_overage: true`.
  Assert the overage indicator element is present
  (`has_element?(view, "[data-test=rate-limit-chip] [data-test=overage-indicator]")`).
  Broadcast with `is_using_overage: false`; assert the indicator is absent.
- *Happy path — ordering*: broadcast `text chunk → rate-limit event →
  text chunk` in sequence. Assert rendered DOM contains, in order, a
  `.chat_intermediate_bubble`, a `[data-test=rate-limit-chip]`, and
  another `.chat_intermediate_bubble` (LazyHTML or sibling-selector
  assertion).
- *Happy path — multiple events per turn*: broadcast three
  `RateLimitEvent`s in a row. Assert three chips render with distinct
  ids, in broadcast order.
- *Unit-level — `format_reset_time/2`*: pure-function test in an
  appropriate test file (can co-locate with existing LiveView test
  helpers or a new `test/destila_web/components/chat_components_test.exs`).
  Scenarios: a future `resets_at` yields a plausible "resets in …"
  string and a non-empty absolute string; `nil` yields `{nil, nil}`;
  a past `resets_at` yields either "resets soon" or "0m"-class
  output — whichever the implementer picks — exercised deterministically
  by passing an explicit `now`.
- *Unit-level — `rate_limit_variant/1`*: returns distinct atoms for each
  of the three known statuses and a neutral fallback for any other
  input (including a string, not just an atom).

**Verification:**
- All three status variants render with distinct `data-status` attributes
  and distinguishable class tokens in the rendered HTML
- Unknown status renders without crashing
- Missing optional fields do not produce runtime errors
- Overage indicator appears iff `is_using_overage` is true
- `mix format` leaves the changes untouched (idempotent format)
- `mix credo --strict` (if in `mix precommit`) passes with no new warnings

---

- [ ] **Unit 3: Confirm turn-completion clears chips & verify no persistence**

**Goal:** Add regression coverage for the two behaviors that Units 1-2
lean on but do not directly assert: chips are cleared when the turn
completes, and chips never reappear on reload.

**Requirements:** R6, R8

**Dependencies:** Units 1 and 2

**Files:**
- Test: `test/destila_web/live/brainstorm_idea_workflow_live_test.exs`

**Approach:**
- Extend the existing `describe "Streaming intermediate bubbles"` block
  with two tests.
- For turn-completion clearing, mirror the existing test at lines
  694-718 (broadcast chunk → assert visible → flip `pe.status` to
  `:awaiting_input` → `send(view.pid, {:workflow_session_updated, ws})` →
  refute visible), substituting a `RateLimitEvent` for the text chunk.
- For persistence, mount the LiveView fresh without broadcasting any
  stream chunk and assert `refute has_element?(view, "[data-test=rate-limit-chip]")`.
  Optionally, broadcast an event, navigate away, re-mount, and assert
  no chip is present — but the fresh-mount check is sufficient given
  Unit 1 proves the assign starts empty.

**Patterns to follow:**
- `test/destila_web/live/brainstorm_idea_workflow_live_test.exs:694-718`
  for the clearing test shape.
- `ClaudeCode.Test.set_mode_to_shared()` and the `setup` stub from
  `brainstorm_idea_workflow_live_test.exs:14-25`.

**Test scenarios:**
- *Integration — clearing*: broadcast a `RateLimitEvent` during
  `:processing`, assert chip visible, flip `pe.status` to `:awaiting_input`
  and send `{:workflow_session_updated, ws}`, assert chip gone and
  `:intermediate_bubbles` in the socket is `[]` (via
  `refute has_element?(view, "[data-test=rate-limit-chip]")`).
- *Integration — fresh mount*: create a session in `:processing`,
  mount, assert no chip exists on first render.

**Verification:**
- Both tests are tagged with the appropriate
  `@tag feature: "brainstorm_idea_workflow", scenario: "..."` — see
  Unit 4.
- `mix test test/destila_web/live/brainstorm_idea_workflow_live_test.exs --only feature:brainstorm_idea_workflow`
  passes.

---

- [ ] **Unit 4: Update Gherkin scenarios and tag linkage**

**Goal:** Add the six new scenarios to
`features/brainstorm_idea_workflow.feature` in the existing
`# --- Streaming Message Bubbles ---` section and ensure every new test
carries a `@tag feature:/scenario:` pair linking to a scenario.

**Requirements:** R9

**Dependencies:** Units 1-3 (the tests that carry the tags exist)

**Files:**
- Modify: `features/brainstorm_idea_workflow.feature`
- Modify: `test/destila_web/live/brainstorm_idea_workflow_live_test.exs`

**Approach:**
- Insert the six scenarios verbatim (from the user prompt) at the end of
  the `# --- Streaming Message Bubbles ---` section, before the
  `# --- Aliveness Indicator ---` section.
- Tag every test added in Units 1-3 with
  `@tag feature: "brainstorm_idea_workflow", scenario: "..."` using the
  exact scenario text. When a single scenario is best covered by two
  tests (e.g. multiple variant tests for the "Allowed rate limit
  event renders as an informational chip" scenario), tag them both to
  the same scenario.
- Double-check that every new scenario in the feature file has at least
  one `@tag scenario: "..."` somewhere in the test module, per the
  BDD feature / test linking rule in CLAUDE.md. Add a coverage stub
  test if any scenario lacks one.

**Test scenarios:**
- Test expectation: none -- this unit only adds Gherkin text and
  `@tag` metadata; behavior is exercised by Units 1-3's tests. The
  post-check is structural (feature scenarios ↔ test tags match) and
  is verified by running `mix test --only feature:brainstorm_idea_workflow`
  successfully after the change.

**Verification:**
- `mix test --only feature:brainstorm_idea_workflow` executes and
  includes the new tests
- `mix test --only "scenario:Rate limit event appears as a transient chip during AI processing"`
  runs at least one test
- Every new scenario has at least one linked test; no dangling scenarios
- `mix precommit` passes

## System-Wide Impact

- **Interaction graph:** The only new consumer of
  `{:ai_stream_chunk, _}` is the existing
  `WorkflowRunnerLive.handle_info/2`. No other subscribers to
  `ai_stream_topic/1` exist in the codebase (verified via repo grep of
  `:ai_stream_chunk`). Persisted-message flow, `AiSessionDetailLive`,
  and the crafting-board listings are unaffected.
- **Error propagation:** Missing-field defensiveness (R7) keeps
  `handle_info` from crashing and tearing down the LiveView socket. A
  crash here would also take out the text-bubble rendering for the same
  turn — worth guarding carefully.
- **State lifecycle risks:** The feature is ephemeral. The only
  lifecycle hook is the existing `:workflow_session_updated` clearing
  path. No DB writes, no ETS, no PubSub subscriptions added.
- **API surface parity:** None. No public APIs change.
- **Integration coverage:** The clearing test (Unit 3) is the
  cross-layer integration signal — it proves that the LiveView
  listener, the assign, the template branch, and the
  `phase_status`-driven clearing all cooperate correctly.
- **Unchanged invariants:**
  - `Destila.AI.ClaudeSession.collect_with_mcp_and_broadcast/2` behaviour
    (broadcasts every item; accumulates text/MCP/ResultMessage into the
    returned map) — *not* modified. `RateLimitEvent` continues to fall
    through the `_ -> acc` clause and is not summarized in the returned
    result.
  - `DestilaWeb.AiSessionDetailLive` rendering — explicitly out of scope.
  - `%Destila.AI.Message{}` schema, `AI.list_messages_for_workflow_session/1`,
    and message persistence — unchanged; rate-limit events never become
    messages.
  - The existing `:text`-bubble UX (dashed border, typing indicator,
    clearing behavior) — preserved byte-for-byte aside from the
    `:for`-branch delegation.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| A missing-field crash (`nil` for `utilization`, `resets_at`, etc.) could tear down the LiveView during processing and also lose any in-flight text bubbles for that turn. | Unit 2 enumerates all-nil and partial-nil edge-case tests. Render helpers defensively return "" / absent markup when fields are missing. |
| An unknown `status` string (because upstream `parse_status/1` passes strings through verbatim) could hit a non-exhaustive `case` and crash. | Unit 2 tests an unknown string explicitly. `rate_limit_variant/1` must have a catch-all `_` clause. |
| Duplicate clearing (explicit + implicit) could cause chips to blink or clear early if someone adds a second reset path. | Decision captured above to **not** add a second path. Unit 3 asserts the single `:workflow_session_updated` path clears chips. |
| Relative-time string depending on wall-clock time could produce flaky tests. | `format_reset_time/2` takes `now` as an argument, enabling deterministic tests. Template calls it with `DateTime.utc_now/0` in production. |
| Over-eager pattern matching on `%{status: :allowed}` inside the chip component could fail on the pass-through unknown status. | `rate_limit_variant/1` is called first on any status and is the sole dispatcher; the chip component never case-matches on status directly. |
| Multiple chips within a single turn could visually overwhelm the chat timeline. | Accepted — out of scope per "Multiple events during the same turn each render as their own chip, in order received". If it becomes a UX problem a future plan can collapse or cap. |

## Documentation / Operational Notes

- No schema migration, no deploy gating, no feature flag. The feature
  becomes visible as soon as the code deploys and the AI emits a
  rate-limit event.
- No monitoring changes required. The existing AI session usage
  tracking already captures rate-limit impact indirectly via
  `ResultMessage.usage`.

## Sources & References

- User prompt (2026-04-20) — authoritative for behavior, constraints,
  and Gherkin scenarios.
- Related code:
  - `lib/destila_web/live/workflow_runner_live.ex:69, 481-524, 566-580`
  - `lib/destila_web/components/chat_components.ex:30-125, 702-715`
  - `lib/destila/ai/claude_session.ex:249-324`
  - `deps/claude_code/lib/claude_code/message/rate_limit_event.ex`
  - `features/brainstorm_idea_workflow.feature` (`# --- Streaming Message Bubbles ---` section)
  - `test/destila_web/live/brainstorm_idea_workflow_live_test.exs:583-744`
- Related plans:
  - `docs/plans/2026-04-15-001-feat-streaming-intermediate-bubbles-plan.md`
    — establishes the `:intermediate_bubbles` assign pattern this plan
    extends.
