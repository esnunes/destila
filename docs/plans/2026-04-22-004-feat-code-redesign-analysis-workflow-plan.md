---
title: Add Code Redesign Analysis workflow
type: feat
status: active
date: 2026-04-22
deepened: 2026-04-22
---

# Add Code Redesign Analysis workflow

## Overview

Introduce a fourth Destila workflow type — `:code_redesign_analysis` — that
analyzes an existing codebase within a user-supplied scope and produces a
redesign proposal plus an agent-ready implementation prompt. Phases 1-3 run
non-interactively; phase 4 is an interactive "Adjustments" phase where the user
can request refinements before marking the workflow done.

The workflow emits four exported markdown artifacts that stream into the
runner's exported-metadata sidebar and let the existing "Implement a Prompt"
workflow consume the final `prompt_generated` output as a source session.

## Problem Frame

Destila users who want to improve an existing area of a codebase currently have
to do three things by hand:
1. Summarize the current behavior of that area.
2. Sketch what a from-scratch design would look like.
3. Translate the delta between "what we have" and "what we'd build today" into a
   prioritized set of improvements and a prompt that can be fed back into the
   `:implement_general_prompt` workflow.

This feature automates steps 1-3 as a multi-phase workflow that reuses
Destila's existing non-interactive AI-session machinery and closes the loop
with `:implement_general_prompt` via the shared `prompt_generated` export key.

## Requirements Trace

- **R1.** A new workflow type named "Code Redesign Analysis" is selectable from
  the workflow type picker and shows an icon, description, and badge.
- **R2.** The creation form collects a project + a free-text **Scope** input
  (e.g., `"entire application"`, `"authentication"`, `"user management"`).
- **R3.** Phases 1-3 are non-interactive. Each exports one or more markdown
  artifacts and auto-advances via `mcp__destila__session` `action:
  "phase_complete"`.
- **R4.** Four artifact keys are produced (all `type: "markdown"`) and appear
  in the sidebar in real time:
  - `requirements_doc` (Phase 1 export)
  - `greenfield_design` (Phase 2 export)
  - `comparison_report` (Phase 3 export)
  - `prompt_generated` (Phase 3 export)
- **R5.** Phase 4 ("Adjustments") is interactive. The user can request
  refinements to any of the four artifacts; the AI re-exports the affected
  key(s) in place. The user marks the workflow done when satisfied.
- **R6.** The `prompt_generated` key must be offered in the existing
  "Implement a Prompt" creation form's source-session picker alongside
  `Brainstorm Idea` outputs.
- **R7.** The workflow uses a hybrid AI-session grouping:
  - Group 1 *Analysis* — Phase 1.
  - Group 2 *Design & Compare* — Phases 2 and 3 share one AI session.
  - Group 3 *Adjustments* — Phase 4.
- **R8.** Behavior is specified in a new
  `features/code_redesign_analysis_workflow.feature` file. Every scenario has
  at least one linked test (`@tag feature: ..., scenario: ...`).
- **R9.** Change is purely additive — no behavior change to the existing
  `:brainstorm_idea`, `:implement_general_prompt`, or `:code_chat` workflows.

## Scope Boundaries

- **Out of scope:** implementing the improvements the workflow proposes — that
  is the downstream job of `:implement_general_prompt`.
- **Out of scope:** Elixir-side truncation, sampling, or glob-pruning of the
  codebase. The agent is trusted to decide coverage using `Glob` / `Grep`.
- **Out of scope:** any changes to `CreateSessionLive` — it already adapts to
  `creation_label/0` and validates project + `input_text`.
- **Out of scope:** new tools, new skills, or changes to
  `session_metadata.ex` / MCP handlers. We reuse the existing contract end
  to end.
- **Out of scope:** a dedicated chat component for this workflow — it reuses
  `DestilaWeb.ChatComponents.chat_phase/1`.

## Context & Research

### Relevant Code and Patterns

- **Workflow behaviour:** `lib/destila/workflows/workflow.ex` — declares the
  callbacks (`groups/0`, `label/0`, `description/0`, `icon/0`, `icon_class/0`,
  `default_title/0`, `completion_message/0`, `creation_label/0`,
  `source_metadata_key/0`) and provides default `phases/0`, `total_phases/0`,
  `phase_name/1`, `phase_columns/0` via `use Destila.Workflows.Workflow`.
- **Workflow registry:** `lib/destila/workflows.ex` — the `@workflow_modules`
  map at lines 35-39 is the single place to register a new workflow module.
- **Phase / group structs:** `lib/destila/workflows/phase.ex` (fields: `name`,
  `initial_prompt`, `non_interactive`, `skills`) and
  `lib/destila/workflows/ai_session_group.ex` (fields: `name`, `phases`,
  `skills`, `allowed_tools`). No Ecto schema — pure data.
- **Closest analog (multi-group, non-interactive):**
  `lib/destila/workflows/implement_general_prompt_workflow.ex`. Mirror its
  tool allowlist (`@implementation_tools`), `skills: ["code_quality"]`, and
  non-interactive / interactive phase mix. Private per-phase prompt functions.
- **Metadata-injection pattern:** `deepen_plan_prompt/1` at
  `lib/destila/workflows/implement_general_prompt_workflow.ex:141-160` reads
  previously-exported metadata via
  `Destila.Workflows.get_metadata(workflow_session.id) |> get_in(["key",
  "markdown" | "text" | "file"])`. Phase 2 (new session) and Phase 4 (new
  session) both follow this pattern in the new workflow.
- **Export upsert:** `Destila.Workflows.upsert_metadata/5` in
  `lib/destila/workflows.ex:292-324` replaces `:value`, `:exported`,
  `:updated_at` on conflict against
  `[:workflow_session_id, :phase_name, :key]`. So the Adjustments phase's
  "re-export in place" contract is satisfied by the existing MCP handler with
  no code change. **But:** the conflict target includes `phase_name`, and
  Phase 4 runs under a different phase name than Phases 1-3. This means a
  re-export from Phase 4 creates a second row keyed under "Adjustments"
  rather than replacing the original row. See Key Technical Decisions and
  Open Questions — this needs to be verified during implementation.
- **Source-session picker:** `Destila.Workflows.list_source_sessions/1` in
  `lib/destila/workflows.ex:59-67` calls
  `list_sessions_with_exported_metadata/1`, which is scoped by metadata key
  alone (no workflow_type filter). That means exporting `prompt_generated`
  automatically makes our sessions selectable in the `:implement_general_prompt`
  picker — **this is the desired behavior** and requires no extra wiring.
- **Crafting-board card / badge:**
  `lib/destila_web/components/board_components.ex:184-192` hardcodes a
  `workflow_label/1` + `workflow_badge_class/1` clause per workflow type. The
  new workflow needs both clauses.
- **Creation form adaptation:** `lib/destila_web/live/create_session_live.ex`
  reads `creation_label/0` and `source_metadata_key/0` to build its form. It
  already handles: the project picker, the free-text input, validation, and
  the "Select existing" tab (shown only when `source_metadata_key/0` is
  non-nil). No changes needed as long as `source_metadata_key/0` is `nil`
  (see Open Questions).
- **Runner / sidebar:** `lib/destila_web/live/workflow_runner_live.ex`
  (`assign_metadata/2` at lines 1348-1354) consumes
  `Destila.Workflows.get_all_metadata/1` and reacts to the
  `metadata_updated` PubSub event emitted by `upsert_metadata/5`. Sidebar
  updates in real time for free.
- **Chat surface:** `DestilaWeb.ChatComponents.chat_phase/1` already renders
  the chat UI, including a "Preparing workspace…" banner during setup. No
  new chat component is needed.

### Institutional Learnings

Searched `docs/solutions/` — no entries directly applicable to this change.
The most relevant prior art is the `:implement_general_prompt` workflow plan
(`docs/plans/2026-03-28-feat-implement-general-prompt-workflow-plan.md`) and
the more recent group-based restructure
(`docs/plans/2026-04-21-001-refactor-workflow-ai-session-groups-plan.md`),
which established the `AISessionGroup` shape we reuse here.

### External References

External research deliberately skipped. The codebase has three well-scoped
precedents (Brainstorm Idea, Implement a Prompt, Code Chat) that show exactly
the patterns this plan needs.

## Key Technical Decisions

- **Register the module as `:code_redesign_analysis`.** Consistent with the
  existing snake-cased atom keys in `@workflow_modules`.
- **Three AI-session groups, four phases.** Phase 2 + Phase 3 share a session
  because the design step and the comparison step are tightly coupled and
  benefit from a warm context. Phase 1 and Phase 4 each get their own
  session (group boundaries) because they are logically independent and
  Phase 4 is interactive.
- **Reuse the `@implementation_tools` allowlist.** Same tools as
  `:implement_general_prompt` — `Read`, `Write`, `Edit`, `Bash`, `Glob`,
  `Grep`, `WebFetch`, `Skill`, `mcp__destila__session`,
  `mcp__destila__service` — and `skills: ["code_quality"]`. The workflow
  does not need `mcp__destila__ask_user_question`: non-interactive phases
  should not ask questions, and Phase 4 uses the regular chat surface for
  refinement requests.
- **Cross-session metadata handoff via `Workflows.get_metadata/1`.** Phase 2
  reads `requirements_doc`, Phase 3 reads `requirements_doc` and
  `greenfield_design`, Phase 4 reads all four artifacts. Each phase's
  prompt function inlines the retrieved markdown into its instructions so
  the new AI session has the prior outputs as context. This is the same
  pattern `deepen_plan_prompt/1` already uses.
- **`source_metadata_key/0` returns `nil`** (see Open Questions for
  rationale). Cross-workflow reuse of this workflow's `prompt_generated`
  output by `:implement_general_prompt` does **not** require our
  `source_metadata_key/0` to be non-nil — it requires only that we export
  under the key `"prompt_generated"`, which we do in Phase 3.
- **Scope is stored in `workflow_session.input_text`.** The existing
  `CreateSessionLive` already routes the free-text input into
  `input_text`. Phase 1's prompt reads it via `workflow_session.user_prompt`
  (the alias the other workflows use — e.g.,
  `task_description_prompt/1:60` and `plan_prompt/1:119`).
- **No Elixir-side scope parsing, globbing, or sampling.** The scope string
  is injected verbatim into the Phase 1 prompt, and the agent decides how
  to use `Glob` / `Grep` to stay within it. This matches the project-wide
  "trust the agent" guideline in CLAUDE.md.
- **Re-exports from Phase 4 must replace the original artifact row, not
  create a second one.** The upsert target is
  `[:workflow_session_id, :phase_name, :key]`, so a naive re-export from
  phase name `"Adjustments"` would leave the original Phase 1/Phase 2/
  Phase 3 rows in place and add a second row under `"Adjustments"`. See
  Open Questions for resolution options.

## Open Questions

### Resolved During Planning

- **Should `source_metadata_key/0` return `"prompt_generated"` or `nil`?**
  The feature description says `:prompt_generated`, but the current code
  uses `source_metadata_key/0` to drive the CreateSessionLive "Select
  existing" picker — i.e., it controls what this workflow **consumes**,
  not what it **produces**. Code Redesign Analysis consumes a free-text
  scope, not a prior prompt, so the right value is **`nil`**. The
  requirement "the `prompt_generated` key must be selectable as a source
  prompt in Implement a Prompt's picker" is satisfied independently by
  exporting under key `"prompt_generated"` — because
  `list_sessions_with_exported_metadata/1`
  (`lib/destila/workflows.ex:214-226`) is scoped by key alone, our
  sessions show up in any workflow whose `source_metadata_key/0` is
  `"prompt_generated"`. If implementation reveals a stronger reason to
  honor the original value, flag it and surface a follow-up.
- **Do we need to scope `list_sessions_with_exported_metadata/1` by
  `workflow_type`?** No. Both Brainstorm Idea and Code Redesign Analysis
  produce a "prompt ready to hand to an implementation agent" under
  `prompt_generated`; the Implement a Prompt picker is *supposed* to see
  both. No query scoping or key rename is needed.
- **Are Phase 4 re-exports visible to `list_source_sessions/1`?** Only
  exports with `exported: true` surface, and only from non-archived,
  completed sessions (`done_at IS NOT NULL`). Both Phase 3 and Phase 4
  exports flow through `upsert_metadata` with `exported: true`, so this
  works as long as row identity survives re-export — covered below.

### Deferred to Implementation

- **Confirm re-export upsert behavior across phase boundaries.**
  `upsert_metadata/5`'s conflict target is
  `[:workflow_session_id, :phase_name, :key]`. When Phase 4 re-exports
  `greenfield_design` (originally written under phase name `"Greenfield
  Design"`), the insert would write under phase name `"Adjustments"`
  instead of replacing the original row. Verify during implementation
  and, if the observed behavior doesn't satisfy R5, fix by either (a)
  keying re-exports to the original phase name on the server side, or
  (b) having the Phase 4 prompt call `export` with metadata that
  overwrites by `(workflow_session_id, key)` only. Prefer option (a)
  because it preserves the existing contract for other workflows. Write
  the fix as its own unit, not as part of the workflow module unit.
- **Final copy for `label/0`, `description/0`, `default_title/0`,
  `completion_message/0`, `icon/0`, `icon_class/0`, and the badge color.**
  Strawman values are given in Unit 1's Approach — they may be tightened
  during review, but no architectural impact.
- **Exact Gherkin scenario list.** The plan enumerates the scenario set
  the feature file must cover (R8). The final wording lands in Unit 4 and
  may evolve during test writing; every final scenario must still have a
  linked test.

## Implementation Units

- [ ] **Unit 1: Create the workflow module and register it.**

**Goal:** Add `Destila.Workflows.CodeRedesignAnalysisWorkflow` implementing
the `Destila.Workflows.Workflow` behaviour, and wire it into
`@workflow_modules`.

**Requirements:** R1, R2, R3, R4, R5, R6, R7, R9.

**Dependencies:** None.

**Files:**
- Create: `lib/destila/workflows/code_redesign_analysis_workflow.ex`
- Modify: `lib/destila/workflows.ex` (add
  `code_redesign_analysis: Destila.Workflows.CodeRedesignAnalysisWorkflow`
  to `@workflow_modules` at lines 35-39)

**Approach:**
- Use `use Destila.Workflows.Workflow` and alias
  `Destila.Workflows.{AISessionGroup, Phase}`.
- Define `@analysis_tools` with the same 10 tools as
  `@implementation_tools` in `implement_general_prompt_workflow.ex:29-40`
  (no `mcp__destila__ask_user_question`).
- `groups/0` returns three `AISessionGroup`s, each with
  `skills: ["code_quality"]` and `allowed_tools: @analysis_tools`:
  1. `%AISessionGroup{name: "Analysis", phases: [%Phase{name: "Extract
     Requirements", initial_prompt: &extract_requirements_prompt/1,
     non_interactive: true}]}`.
  2. `%AISessionGroup{name: "Design & Compare", phases: [%Phase{name:
     "Greenfield Design", initial_prompt: &greenfield_design_prompt/1,
     non_interactive: true}, %Phase{name: "Compare & Improve",
     initial_prompt: &compare_and_improve_prompt/1, non_interactive:
     true}]}`.
  3. `%AISessionGroup{name: "Adjustments", phases: [%Phase{name:
     "Adjustments", initial_prompt: &adjustments_prompt/1}]}` (not
     `non_interactive`).
- Callbacks:
  - `creation_label/0 → "Scope"`.
  - `source_metadata_key/0 → nil` (see Resolved Open Questions).
  - `label/0 → "Code Redesign Analysis"`.
  - `description/0 → "Analyze an area of a codebase and propose a
    redesign with an implementation prompt"` (tune during review).
  - `icon/0 → "hero-arrow-path-rounded-square"` or similar; pair with
    an `icon_class/0` distinct from the existing three (e.g.,
    `"text-info"`). Finalize during review.
  - `default_title/0 → "New Redesign"`.
  - `completion_message/0 → "Redesign analysis complete! Requirements,
    greenfield design, comparison, and implementation prompt are ready."`.
- Private prompt functions:
  - `extract_requirements_prompt/1` reads `workflow_session.user_prompt`
    (the scope string) and instructs the agent to analyze the code
    restricted to that scope, prefer `Glob`/`Grep`, and export the
    resulting requirements as `mcp__destila__session` `action: "export",
    key: "requirements_doc", type: "markdown"`, then call
    `action: "phase_complete"`. Mention that Write/Edit scratch edits are
    for the agent's own benefit and must not be committed (the worktree
    is isolated).
  - `greenfield_design_prompt/1` reads `requirements_doc` from
    `Destila.Workflows.get_metadata(ws.id)` via
    `get_in(["requirements_doc", "markdown"])`, inlines it into the
    prompt, and instructs export under `greenfield_design` + auto-advance.
  - `compare_and_improve_prompt/1` reads both `requirements_doc` and
    `greenfield_design`, inlines both, and instructs the agent to export
    two artifacts: `comparison_report` (improvement suggestions grouped
    into Must / Should / Nice-to-have, each item tagged with effort) and
    `prompt_generated` (handoff prompt for an implementation agent), then
    auto-advance.
  - `adjustments_prompt/1` reads all four artifacts via
    `Destila.Workflows.get_metadata(ws.id)` and inlines a short summary.
    Instructs the agent to wait for the user, apply refinements to any
    artifact the user names, re-export the affected key(s) via `action:
    "export"`, and not to call `phase_complete` / `suggest_phase_complete`
    — the user marks this phase done manually (same guard rail as the
    Brainstorm Idea prompt-generation phase and the
    `:implement_general_prompt` adjustments phase).

**Patterns to follow:**
- Module skeleton:
  `lib/destila/workflows/implement_general_prompt_workflow.ex`.
- Metadata injection:
  `deepen_plan_prompt/1` at
  `lib/destila/workflows/implement_general_prompt_workflow.ex:141-160`.
- "User marks done manually" prompt language:
  `prompt_generation_prompt/1` at
  `lib/destila/workflows/brainstorm_idea_workflow.ex:153-185` and
  `adjustments_prompt/1` at
  `lib/destila/workflows/implement_general_prompt_workflow.ex:219-241`.

**Test scenarios:**
- Happy path: `groups/0` returns three groups with the expected `name`,
  `skills == ["code_quality"]`, and the 10-tool allowlist.
- Happy path: flattened `phases/0` order is `["Extract Requirements",
  "Greenfield Design", "Compare & Improve", "Adjustments"]` with
  `non_interactive` flags `[true, true, true, false]`.
- Happy path: `total_phases/0 == 4`, `phase_columns/0` ends with
  `{:done, "Done"}` and has length 5.
- Happy path: `creation_label/0 == "Scope"`, `source_metadata_key/0 ==
  nil`, `default_title/0`, `label/0`, `description/0`,
  `completion_message/0`, `icon/0`, `icon_class/0` all return
  non-empty strings.
- Happy path: `Workflows.groups(:code_redesign_analysis)` equals
  `CodeRedesignAnalysisWorkflow.groups()` (exercises the registry
  dispatcher).
- Integration: `Workflows.group_for_phase(:code_redesign_analysis, 1)`
  returns the Analysis group; `2` and `3` return Design & Compare; `4`
  returns Adjustments; `5` returns `nil`.

**Verification:**
- `mix compile --warnings-as-errors` passes with the new module.
- `Workflows.workflow_types()` now includes `:code_redesign_analysis`.
- Starting IEx and calling
  `Destila.Workflows.CodeRedesignAnalysisWorkflow.groups()` returns the
  three-group shape without raising.

- [ ] **Unit 2: Surface the workflow in crafting board styling.**

**Goal:** Give the new workflow a badge label and color so crafting-board
cards and the runner header render it like the other types.

**Requirements:** R1, R9.

**Dependencies:** Unit 1 (module must exist so the atom key resolves).

**Files:**
- Modify: `lib/destila_web/components/board_components.ex` (add
  `workflow_label(:code_redesign_analysis)` clause near line 184 and
  `workflow_badge_class(:code_redesign_analysis)` clause near line
  189-192, above the `_` fallback).

**Approach:**
- Add `def workflow_label(:code_redesign_analysis), do: "Redesign
  Analysis"` (short label — keep the crafting board card tidy).
- Add `defp workflow_badge_class(:code_redesign_analysis), do:
  "badge-info"` or a color not already taken by the three existing
  workflows (`amber-600`, `badge-primary`, `badge-accent`). `badge-info`
  is currently unused at this call site.

**Patterns to follow:**
- Existing per-type clauses at
  `lib/destila_web/components/board_components.ex:184-192`.

**Test scenarios:**
- Happy path: crafting-board LiveView test renders a running Code
  Redesign Analysis session and asserts the card element contains the
  new label text (`"Redesign Analysis"`). Covered by Unit 4's crafting
  board scenario.

**Verification:**
- No changes to other workflows' rendered output.
- Adding a session via seeds or IEx shows the new badge on
  `/crafting-board`.

- [ ] **Unit 3: Verify and, if necessary, harden re-export upsert across
  phase boundaries.**

**Execution note:** Start by writing a test that asserts the observed
behavior, not by changing code. Only touch production code if the test
shows a mismatch with R5.

**Goal:** Confirm that Phase 4 re-exports of `requirements_doc`,
`greenfield_design`, `comparison_report`, and `prompt_generated` replace
the original rows in place (R5). If they don't (because phase_name is
part of the conflict target), adjust the server-side export handler so
exported artifacts behave as per-session singletons keyed by
`(workflow_session_id, key)`.

**Requirements:** R5.

**Dependencies:** Unit 1 (workflow module), but the test and any fix are
self-contained in this unit.

**Files:**
- Test: `test/destila/workflows_metadata_test.exs` (add scenarios
  specifically for exported re-exports across phase names).
- Potentially modify: `lib/destila/workflows.ex` (the `upsert_metadata/5`
  function at lines 292-324) and/or `lib/destila/ai/conversation.ex`
  (the export handler at lines 106-127 that calls `upsert_metadata/5`
  with the current phase name).
- Potentially modify:
  `lib/destila/workflows/session_metadata.ex` schema changeset if the
  conflict target needs to change. **Not** a migration — the unique
  constraint currently at the DB level is on
  `[:workflow_session_id, :phase_name, :key]`; weakening it to
  `(workflow_session_id, key)` for exported rows would require either a
  new partial index (SQLite supports this) or a separate
  `on_conflict` strategy keyed only by `(workflow_session_id, key)`
  when `exported: true`.

**Approach:**
- Write a failing characterization test first:
  - Upsert `requirements_doc` under phase name `"Extract Requirements"`
    with `exported: true`.
  - Upsert `requirements_doc` again under phase name `"Adjustments"`
    with `exported: true` and a different value.
  - Assert that `Workflows.get_exported_metadata/1` returns exactly one
    row for `requirements_doc` and that its value is the second one.
- If the test passes today (single-row behavior), leave code untouched
  and keep the test as a regression guard. **Unlikely** — the unique
  index at `lib/destila/workflows/session_metadata.ex` covers
  `(workflow_session_id, phase_name, key)`, so two different phase
  names will produce two rows.
- Two viable fixes. Evaluate both against the concurrency + crash
  scenarios below and pick one before coding:
  - **Option A (transactional delete-then-upsert).** In
    `upsert_metadata/5`, when `exported: true`, open a
    `Repo.transaction/1` that first deletes any pre-existing rows
    matching `workflow_session_id == ^id AND key == ^key AND exported
    == true AND phase_name != ^phase_name`, then runs the existing
    upsert. Scope the delete strictly by `exported == true` so non-
    exported rows with the same key in a different phase are never
    touched. Broadcast `:metadata_updated` exactly once, after commit
    — never mid-transaction.
  - **Option B (partial unique index).** Add a migration introducing
    a partial unique index
    `(workflow_session_id, key) WHERE exported = 1` alongside the
    existing full index. Then either split the code path — exported
    writes use `conflict_target: {:unsafe_fragment, ...}` keyed on
    `(session, key)` against the partial index, non-exported writes
    keep today's target — or collapse exported rows to a single
    "Exported" sentinel phase name via a new column default. Cleaner
    invariant (DB enforces it, no race window), but requires a
    migration and an Ecto `on_conflict` shape that's fiddly on SQLite
    (must use the named partial index).
- Decision rule: if the concurrent-write or crash-simulation tests
  below expose data-loss gaps in Option A that can't be closed with a
  transaction, switch to Option B in this same unit. Otherwise prefer
  Option A — it adds no migration and is localized to one function.
- The non-exported metadata path is unchanged under either option.

**Patterns to follow:**
- Baseline upsert tests: `test/destila/workflows_metadata_test.exs`
  (the upsert-on-conflict scenarios at roughly lines 18-50).
- Transaction usage elsewhere in the app:
  `lib/destila/workflows.ex` already imports `Ecto.Query` and uses
  `Repo` directly — follow the same idioms for the new
  `Repo.transaction/1` wrapper.

**Test scenarios:**
- Happy path: same phase name, same key, repeated upsert → one row,
  second value wins, `updated_at` advances. (Regression guard.)
- Happy path: different phase names, same key, both `exported: true`
  → after the fix, exactly one exported row for that key; the later
  write wins.
- Edge case: Phase 3 exports both `comparison_report` and
  `prompt_generated`; Phase 4 re-exports only `comparison_report`.
  Assert the original Phase 3 `prompt_generated` row survives
  untouched (cross-key isolation — the delete must be scoped by
  `key`).
- Edge case: a non-exported row with the same key exists under the
  original phase name; an exported Phase 4 re-export of that key
  must leave the non-exported row untouched. (Delete must be scoped
  by `exported == true`.)
- Edge case: re-export → re-export (two consecutive Phase 4 re-
  exports of the same key) → still exactly one row, final value
  wins.
- Concurrency / race: two tasks calling `upsert_metadata/5` in
  parallel with `exported: true`, same session/key, different
  phase names, different values. Assert exactly one exported row
  remains and its value is one of the two inputs. Uses
  `Task.async/1` + `Task.await/2` against the SQLite writer.
- Error path (atomicity): stub or mock `Repo.insert/2` to raise
  after the delete portion of the transaction. Assert the original
  row survives (transaction rolls back) and
  `get_exported_metadata/1` still returns the original value.
  Feasible via a test-only wrapper or by swapping the `Repo`
  module in test config; if neither is tractable, fall back to a
  property-style test that asserts the invariant after many random
  interleavings.
- PubSub: subscribe to the session's topic via
  `Destila.PubSubHelper` (or `Phoenix.PubSub.subscribe/2` against
  the same topic `upsert_metadata/5` broadcasts on), perform a
  Phase 4 re-export, assert exactly one `:metadata_updated` message
  arrives for that export (delete + upsert should not produce two
  events).
- Integration: start a `:code_redesign_analysis` session, drive
  Phases 1-3 to export all four keys, then simulate a Phase 4
  re-export of a new `comparison_report` value and assert exactly
  one exported row for each of the four keys. (Also covered end to
  end by the LiveView test in Unit 4.)

**Verification:**
- All new characterization tests pass.
- Existing `test/destila/workflows_metadata_test.exs` tests still
  pass (no regression in brainstorm / implement / code-chat upsert
  behavior).
- `mix test test/destila/` passes.
- Audit the exported-metadata read sites
  (`lib/destila/workflows.ex:214-226`, `get_exported_metadata/1` at
  `lib/destila/workflows.ex:333-351`, `WorkflowRunnerLive.assign_metadata/2`,
  `CreateSessionLive` source picker) — none should be seeing
  duplicate exported rows after the fix.

- [ ] **Unit 4: Write the Gherkin feature file and LiveView tests.**

**Goal:** Lock behavior with a new `.feature` file and a LiveView test
module mirroring the scenarios. Extend `test/destila/workflow_test.exs`
with structure assertions for the new workflow.

**Requirements:** R1-R8, R9.

**Dependencies:** Unit 1 (module to assert against). Can proceed in
parallel with Unit 2 and Unit 3 once Unit 1 is landed.

**Files:**
- Create: `features/code_redesign_analysis_workflow.feature`.
- Create: `test/destila_web/live/code_redesign_analysis_workflow_live_test.exs`.
- Modify: `test/destila/workflow_test.exs` (add a `describe
  "CodeRedesignAnalysisWorkflow basics"` block and extend the
  non_interactive-flags test to include the new workflow).

**Approach:**
- **Feature file** mirrors the section structure of
  `features/implement_general_prompt_workflow.feature`. Required
  scenarios (full list — every one must have at least one linked test):
  1. Workflow type selection shows the new workflow.
  2. Creation form with scope and project selection.
  3. Creation form requires a scope.
  4. Creation form requires a project.
  5. Creation form shows scope hint examples ("entire application",
     "authentication", "user management").
  6. Setup banner shows "Preparing workspace…" until the worktree is
     ready.
  7. Phase 1 — Non-interactive AI extracts requirements and exports
     `requirements_doc` + auto-advances.
  8. Phase 2 — Non-interactive AI proposes greenfield design and
     exports `greenfield_design` + auto-advances (new AI session —
     prompt includes `requirements_doc`).
  9. Phase 3 — Non-interactive AI compares and exports both
     `comparison_report` (Must / Should / Nice-to-have tiers with
     effort tags) and `prompt_generated` + auto-advances.
  10. Non-interactive phase shows Cancel / Retry on stop or error
      (reuses runner behavior).
  11. Analysis stays within the chosen scope (agent is instructed to
      restrict work to that scope).
  12. All four exported keys appear in the exported-metadata sidebar
      in real time.
  13. Phase 4 — Adjustments phase is interactive, shows a text input,
      and the user can request refinements that re-export affected
      keys.
  14. Phase 4 — "Mark as Done" is enabled when idle and disabled
      while the AI is processing.
  15. Done session can be reopened.
  16. Crafting board shows the workflow with the "Redesign Analysis"
      badge.
- **LiveView test module** follows the setup and helpers pattern in
  `test/destila_web/live/implement_general_prompt_workflow_live_test.exs`:
  - `@moduledoc` referencing
    `features/code_redesign_analysis_workflow.feature`.
  - `@feature "code_redesign_analysis_workflow"` module attribute.
  - `setup` block using `ClaudeCode.Test.set_mode_to_shared/0`
    (`deps/claude_code/lib/claude_code/test.ex:201-203`) and
    `ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts -> [...] end)`
    (`deps/claude_code/lib/claude_code/test.ex:133-157`).
  - Per-scenario tests tagged `@tag feature: @feature, scenario:
    "..."` — every scenario from the feature file has at least one
    matching test. Copy (don't share) the helpers from the
    implement-general-prompt test module so both modules stay
    self-contained. Because
    `create_implement_session/2` there hardcodes
    `workflow_type: :implement_general_prompt` and
    `total_phases: 7`, **write a fresh
    `create_redesign_session/2` helper** in this module with
    `workflow_type: :code_redesign_analysis` and `total_phases: 4`;
    keep its `pe_status` contract the same (default `:processing`;
    `:setup` sentinel skips `PhaseExecution` creation).
- **Non-interactive phase stub shape.** To drive Phase 1, 2, or 3
  auto-advance, return this ordered event list from
  `ClaudeCode.Test.stub/2`:
  1. `ClaudeCode.Test.text("...")` — intermediate assistant text
     (optional; adds realism).
  2. One `ClaudeCode.Test.tool_use("mcp__destila__session", %{
     "action" => "export", "key" => "<artifact_key>", "type" =>
     "markdown", "value" => "..."})` per artifact the phase
     produces (Phase 3 emits two).
  3. One `ClaudeCode.Test.tool_use("mcp__destila__session",
     %{"action" => "phase_complete", "message" => "..."})` to
     trigger auto-advance.
  4. `ClaudeCode.Test.result("...")` — optional; auto-appended by
     `build_stream/2` if omitted
     (`deps/claude_code/lib/claude_code/test.ex:566-586`).
  For multi-phase tests that need different stub sequences across
  turns (the default stub is called on every new AI session), mirror
  the `Agent` counter pattern at
  `test/destila_web/live/brainstorm_idea_workflow_live_test.exs:328-346`
  — the stub closure reads and increments an `Agent` counter and
  branches on the invocation index. Required for the Adjustments
  scenario (Phase 4 re-export is a second-turn response).
- **Phase-advance assertion.** After the stubbed `phase_complete`
  fires, the runner advances via a PubSub message. The reliable
  pattern (see
  `test/destila_web/live/brainstorm_idea_workflow_live_test.exs:354-364`)
  is: call `render(view)` once to flush, then re-mount with a fresh
  `live(conn, ~p"/sessions/#{ws.id}")`, then assert the new header
  text — e.g. `assert html =~ "Phase 2/4"` and `assert html =~
  "Greenfield Design"`. Do not rely on same-mount re-render races.
- **Sidebar / exported-metadata assertions.** Element IDs used by
  existing tests:
  - Sidebar container: `#metadata-sidebar`,
    `#metadata-sidebar-content`.
  - Empty state text: `"No metadata exported yet"`.
  - Per-entry id prefix: `[id^='metadata-entry-']`.
  - Inline markdown card id prefix: `[id^='export-md-']` with
    `[data-content]` (see
    `test/destila_web/live/markdown_metadata_viewing_live_test.exs:171-184`).
  - Markdown view button:
    `button[phx-click='open_markdown_modal'][phx-value-id]`.
  - Keys are humanized in the sidebar — assert on
    `"Requirements Doc"`, `"Greenfield Design"`, `"Comparison Report"`,
    `"Prompt Generated"` (not the raw keys).
  - For deterministic sidebar state without stubbing a full AI turn,
    seed directly via
    `Destila.Workflows.upsert_metadata(ws.id, phase_name, key,
    %{"markdown" => "..."}, exported: true)` — pattern at
    `test/destila_web/live/markdown_metadata_viewing_live_test.exs:80-87`.
- **Cancel / Retry assertions** (mirror
  `test/destila_web/live/implement_general_prompt_workflow_live_test.exs:181-273`):
  - Running non-interactive phase (`pe_status: :processing`):
    `refute has_element?(view, "textarea[name='content']")`,
    `assert has_element?(view, "#cancel-phase-btn")`.
  - Errored non-interactive phase (`pe_status: :awaiting_input` in
    a non-interactive phase):
    `assert has_element?(view, "#retry-phase-btn")`,
    `refute has_element?(view, "#cancel-phase-btn")`.
  - Retry: `view |> element("#retry-phase-btn") |> render_click()`;
    reload with `Destila.Workflows.get_workflow_session!(ws.id)`
    and assert `Destila.Workflows.Session.phase_status(ws) in
    [:processing, :awaiting_input]` (race-tolerant).
- **Adjustments-phase (Phase 4) test pattern — new territory.**
  No existing test combines a user-submitted text form with a
  stubbed AI export response, so the plan introduces it. Compose
  two existing pieces:
  - User text submission:
    `view |> form("form[phx-submit='send_text']", %{"content" =>
    "Tighten the comparison report"}) |> render_submit()`
    (pattern at
    `test/destila_web/live/brainstorm_idea_workflow_live_test.exs:261-265`).
  - Second-turn AI stub returning
    `text + tool_use(export, key: "comparison_report") + result`
    using the `Agent` counter idiom so Phase 4's initial mount
    doesn't also trigger the export.
  - After submission, assert the sidebar's `comparison_report`
    entry's rendered markdown equals the new value (via the
    `[data-content]` attribute or by querying
    `Destila.Workflows.get_exported_metadata/1` directly).
- **ClaudeCode.Test reference.** All test helpers live in
  `deps/claude_code/lib/claude_code/test.ex`. Key builders:
  `text/2` (line 276-290), `tool_use/3` (line 306-331 — use this
  for all `mcp__destila__session` calls, with string keys in the
  input map), `result/2` (line 437-446). The test adapter is
  already wired via `config :claude_code, adapter: {ClaudeCode.Test,
  ClaudeCode}` in `config/test.exs`; no extra setup beyond
  `set_mode_to_shared/0` in the test module's `setup` block.
- **Structure tests** in `test/destila/workflow_test.exs`:
  - Add `alias Destila.Workflows.CodeRedesignAnalysisWorkflow`.
  - New `describe` block asserting `total_phases/0 == 4`,
    `phase_name/1` mapping, `phase_columns/0` shape,
    `creation_label/0 == "Scope"`, `source_metadata_key/0 == nil`.
  - Extend the `groups/0 shape` describe with a test that the new
    workflow has three groups (`Analysis`, `Design & Compare`,
    `Adjustments`) each with `skills == ["code_quality"]` and the
    10-tool allowlist, and that the flattened phase names and
    `non_interactive` flags are `[{"Extract Requirements", true},
    {"Greenfield Design", true}, {"Compare & Improve", true},
    {"Adjustments", false}]`.
  - Extend `Workflows.group_for_phase/2` tests with assertions for
    the new workflow.

**Patterns to follow:**
- Feature file style: `features/implement_general_prompt_workflow.feature`
  and `features/brainstorm_idea_workflow.feature`.
- LiveView test scaffolding: existing
  `implement_general_prompt_workflow_live_test.exs` lines 1-82 and
  its per-scenario tests at lines 84+. Mirror the
  `ClaudeCode.Test.stub/2` usage to drive non-interactive phases to
  completion without a real AI.
- Structure assertions: `test/destila/workflow_test.exs:38-146`.

**Test scenarios:**
This unit *is* the test scenarios. Scope it to the list above; do
not invent new scenarios beyond what the feature file ends up
containing. Before closing the unit, cross-check that every
`Scenario:` line in the feature file has at least one matching
`@tag scenario: ...` in the test module; if any scenario was dropped
during drafting, remove its tag references too (per the project
Gherkin linking rules in CLAUDE.md).

**Verification:**
- `mix test --only feature:code_redesign_analysis_workflow` runs
  every linked test and all pass.
- `mix test test/destila/workflow_test.exs` still passes and now
  covers the new workflow.
- Every `Scenario:` in
  `features/code_redesign_analysis_workflow.feature` has a matching
  `@tag scenario:` in the LiveView test module.

- [ ] **Unit 5: Precommit and integration sweep.**

**Goal:** Make sure the additive change doesn't break existing tests or
formatters, and that the crafting board, runner, and picker all behave
end to end.

**Requirements:** R9.

**Dependencies:** Units 1-4.

**Files:** None directly. This unit touches only what `mix precommit`
surfaces.

**Approach:**
- Run `mix precommit` (per CLAUDE.md project guidelines) and fix any
  formatting, Credo, or unused-binding warnings the new module
  introduces.
- Boot the app (`elixir --sname destila -S mix phx.server`) and click
  through once:
  - `/workflows` shows the new option with the new description.
  - `/workflows/code_redesign_analysis` shows the creation form with
    "Scope" label (and no "Select existing" tab).
  - Submitting with project + scope redirects to the runner.
  - After stubbed AI phases export, the sidebar shows all four
    artifacts and clicking each opens the markdown viewer.
  - A completed session shows up in Implement a Prompt's source
    picker (its `prompt_generated` export is visible).
  - Crafting board renders the new badge.
- If the re-export unit (Unit 3) produced a schema/constraint change,
  confirm `mix ecto.migrate` is a no-op (we only touched the
  `on_conflict` strategy, not the schema).

**Test scenarios:**
- Test expectation: none — this is a smoke verification after
  landing. Any behavior regression caught here becomes a fix in the
  owning unit, not a new test in this unit (tests land with their
  owning unit).

**Verification:**
- `mix precommit` exits 0.
- Manual sweep above passes without errors in the browser console or
  server logs.
- Git worktree has only the expected diff (new workflow file,
  registry entry, board components, feature file, test files,
  optional metadata handler tweak from Unit 3).

## System-Wide Impact

- **Interaction graph:** The new workflow enters via the existing
  `/workflows` picker, runs through `WorkflowRunnerLive`, emits
  `metadata_updated` PubSub events that the sidebar already handles,
  and feeds output into the existing `/workflows/implement_general_prompt`
  source picker. No new subscriptions, channels, or routes.
- **Error propagation:** Same as the other non-interactive workflows —
  if the AI session errors out, `PhaseExecution` enters an error state
  and the runner renders the built-in Retry button. Verified by
  scenario #10 in the feature file.
- **State lifecycle risks:** The only novel lifecycle concern is
  re-export of existing keys from a later phase (Unit 3). Covered
  explicitly.
- **API surface parity:** New module implements every `@callback` on
  the Workflow behaviour; the compiler will enforce this. No other
  workflow's behavior changes.
- **Integration coverage:** The LiveView test in Unit 4 exercises the
  full non-interactive flow end to end against a stubbed AI. Unit 3's
  integration scenario exercises the cross-phase re-export path that
  unit tests alone would not prove.
- **Unchanged invariants:**
  - Brainstorm Idea's `prompt_generated` semantics are untouched.
  - Implement a Prompt's `source_metadata_key = "prompt_generated"`
    contract is preserved; it now sees two source-workflow types
    instead of one — this is the desired behavior per R6.
  - `CreateSessionLive`, `WorkflowRunnerLive`,
    `DestilaWeb.ChatComponents`, the MCP `session` tool, and the
    `session_metadata` schema all see no public-interface change.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Phase 4 re-exports create duplicate rows under a different `phase_name`, breaking the "re-export in place" contract (R5). | Unit 3 writes a characterization test first and then fixes the export handler only if the observed behavior fails the test. |
| `source_metadata_key/0 → nil` is wrong and the workflow was meant to consume prior prompts. | Flagged as a Resolved Open Question with clear rationale. If implementation reveals otherwise, set it to `"prompt_generated"` in a follow-up — it is a one-line change, and the `@implementation_tools` allowlist already handles both shapes. |
| Two workflows writing the same export key (`prompt_generated`) confuse users in the Implement a Prompt picker. | The picker already shows session title, project, and timestamp per row. The workflow-type badge on each row (rendered by `list_source_sessions` consumers) disambiguates. Verified manually in Unit 5. |
| Non-interactive agent gets overwhelmed on a very broad scope ("entire application") and times out. | The prompt instructs the agent to lean on `Glob`/`Grep` and to prioritize representative files rather than reading everything. If this turns out insufficient, iterate on the prompt — not on Elixir-side truncation (per CLAUDE.md). |
| Adjustments phase agent accidentally calls `phase_complete`. | Phase 4 prompt explicitly forbids calling `phase_complete` / `suggest_phase_complete` — mirrors the guard rail in the Brainstorm Idea prompt-generation phase and the `:implement_general_prompt` adjustments phase. |
| Scratch files written during Phase 1 analysis get committed accidentally. | Each AI session runs in an isolated worktree, so stray commits can't leak into main. The prompts add a reminder not to commit scratch work as a safety net. |

## Documentation / Operational Notes

- Update the Destila README or in-app help text only if the existing
  copy enumerates workflow types explicitly. Spot-check during Unit 5.
- No migrations unless Unit 3 requires a changed conflict target. If
  it does, include the migration in Unit 3's file list and confirm
  `mix ecto.migrate` is a no-op on dev before closing the unit.
- No environment variables, no feature flags, no rollout gates — the
  change is additive and takes effect as soon as it ships.

## Sources & References

- Workflow registry: `lib/destila/workflows.ex:35-67`,
  `lib/destila/workflows.ex:214-226`,
  `lib/destila/workflows.ex:292-324`.
- Workflow behaviour:
  `lib/destila/workflows/workflow.ex`.
- Existing workflow modules:
  `lib/destila/workflows/brainstorm_idea_workflow.ex`,
  `lib/destila/workflows/implement_general_prompt_workflow.ex`,
  `lib/destila/workflows/code_chat_workflow.ex`.
- Crafting-board components:
  `lib/destila_web/components/board_components.ex:184-192`.
- Runner / sidebar:
  `lib/destila_web/live/workflow_runner_live.ex` (`assign_metadata/2`
  around lines 1348-1354).
- Existing Gherkin & LiveView tests:
  `features/implement_general_prompt_workflow.feature`,
  `test/destila_web/live/implement_general_prompt_workflow_live_test.exs`,
  `test/destila/workflow_test.exs`.
- Related PRs/plans:
  `docs/plans/2026-03-28-feat-implement-general-prompt-workflow-plan.md`,
  `docs/plans/2026-04-21-001-refactor-workflow-ai-session-groups-plan.md`.
