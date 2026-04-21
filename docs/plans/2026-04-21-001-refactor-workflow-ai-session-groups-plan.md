---
title: Restructure workflows around AI session groups
type: refactor
status: active
date: 2026-04-21
---

# Restructure workflows around AI session groups

## Overview

Workflow definitions in `Destila.Workflows` currently express "which phases share an AI session" implicitly, via a per-phase `:session_strategy` flag that only ever takes values `:resume` (the default) or `:new`. This refactor replaces that flag with an explicit grouping: each workflow returns an ordered list of `AISessionGroup` structs, and each group owns the phases that share an AI session. The group's skills become the AI session's real SDK `system_prompt`, and the group's `allowed_tools` are applied when the session starts. User-observable behavior is unchanged across all three workflows.

## Problem Frame

Today the runtime has no first-class concept of an "AI session group." Instead:

- `Destila.Workflows.Phase` carries `:session_strategy`, `:allowed_tools`, and `:skills` per phase.
- `Destila.AI.Conversation.phase_start/1` assembles the SDK prompt body by concatenating `# Tools`, `# Skills`, `# Service Status`, and `# Prompt` sections into the *first user message*, with tools injected only when `claude_session_id` is `nil`.
- `handle_session_strategy/2` checks `:session_strategy` and, when `:new`, stops the current `ClaudeSession` and inserts a fresh `AI.Session` row.
- `Destila.AI.SessionConfig.session_opts_for_workflow/3` forwards phase-level `:allowed_tools` to `ClaudeCode.start_link/1` and tries to extract `:session_strategy: {_action, opts}` — a tuple shape that no workflow ever uses.

This mixes three unrelated concerns in one struct: (1) how to render the first-turn message, (2) the SDK-level system prompt and tools scope, and (3) where to cut the AI session. Making groups explicit cleanly separates them: **skills are the system prompt**, **tools are scoped at session start**, and **a new group implies a new AI session**.

## Requirements Trace

- R1. Introduce `Destila.Workflows.AISessionGroup` with `name`, `skills`, and `allowed_tools`; workflows return `groups/0`; the `Workflow` macro derives `phases/0` by flattening groups so every existing consumer (`phase_columns`, `phase_name`, `total_phases`, `current_phase` indexing, sidebar, board) works unchanged.
- R2. Update `Destila.Workflows.Phase`: rename `:system_prompt` → `:initial_prompt`; remove `:session_strategy` and `:allowed_tools`; keep `:name`, `:non_interactive`, and `:skills` (as per-phase extras).
- R3. Pass the group's assembled skill body to ClaudeCode as the `system_prompt` SDK option (replacing the default CLI system prompt) and the group's `allowed_tools` as `:allowed_tools` at session start.
- R4. Remove `# Tools` and `# Skills` sections from the kickoff message body in `Conversation.phase_start/1`. The body becomes: optional `# Service Status` block + `# Prompt` containing the phase's `initial_prompt`, with phase-extra skills (if any) prefixed as a `# Skills (additional)` section.
- R5. Replace `handle_session_strategy/2` with group-boundary detection: when entering a phase whose group differs from the previous phase's group, stop the current `ClaudeSession` and create a fresh `AI.Session` (carrying over `worktree_path`). Within a group, the existing resume path is unchanged.
- R6. Preserve auto-injection of the `non_interactive` skill for autonomous phases via the phase-extras concatenation (not the group's system prompt).
- R7. Preserve dedup semantics of `Skills.assemble_skills/1` in both (a) the group's SDK `system_prompt` assembly and (b) the phase's `# Skills (additional)` body section, with the group's set taking precedence so a phase doesn't redundantly re-inject a skill the group already provides.
- R8. Map the three existing workflows per the brief: `BrainstormIdeaWorkflow` → 1 group (4 phases); `CodeChatWorkflow` → 1 group (1 phase) with `allowed_tools` and `skills: ["code_quality"]` moved to the group; `ImplementGeneralPromptWorkflow` → 2 groups split at `Work`, with `code_quality` on both groups.
- R9. Keep `workflow_sessions.current_phase` as a 1-based integer over the flattened phase list. No DB migration.

## Scope Boundaries

- **Not** rewriting `Conversation.send_message/2`, `handle_ai_result/2`, or `handle_ai_error/2` — only `phase_start/1` and the replacement for `handle_session_strategy/2`.
- **Not** migrating or touching any existing `AI.Session` rows or `workflow_sessions.current_phase` values. The field keeps its 1-based-flattened meaning.
- **Not** adding a forward-compatibility shim for live Claude sessions that resumed with the old shape — the Claude SDK retains the original system prompt for the lifetime of a resumed session, and that is accepted behavior.
- **Not** changing any `.feature` file. Phase counts, sidebar AI-session counts, and the `Work`-boundary behavior are preserved.
- **Not** introducing per-group database tables or new external API surface. The `Workflow` behaviour, its public callbacks, and `Destila.Workflows` dispatcher functions remain stable for callers outside the three touched modules.

## Context & Research

### Relevant Code and Patterns

- `lib/destila/workflows/phase.ex` — current `%Phase{}` struct with `:name`, `:system_prompt`, `:non_interactive`, `:allowed_tools`, `:session_strategy`, `:skills`.
- `lib/destila/workflows/workflow.ex` — behaviour + `__using__` macro that generates `total_phases/0`, `phase_name/1`, `phase_columns/0` from `phases/0`. Any addition must preserve these generated functions unchanged from the callers' perspective.
- `lib/destila/workflows.ex:71-76` — dispatcher delegates to `workflow_module/1`. Need a new `groups/0` dispatcher alongside `phases/0`.
- `lib/destila/workflows/brainstorm_idea_workflow.ex`, `code_chat_workflow.ex`, `implement_general_prompt_workflow.ex` — three workflow modules with flat `phases/0` lists to be replaced by `groups/0`.
- `lib/destila/workflows/skills.ex` — `assemble_skills/1` already does `always_included() ++ by_identifiers(phase_skills) |> Enum.uniq_by(& &1.identifier)`. Pattern to reuse for both group skills and phase-extra skills; dedup semantics must be preserved.
- `lib/destila/ai/session_config.ex:17-62` — builds ClaudeCode opts from phase def + `AI.Session`. `session_strategy: {_action, opts}` branch at line 22 is vestigial and goes away. `:allowed_tools` forwarding at lines 52-59 moves to be group-sourced.
- `lib/destila/ai/conversation.ex:20-68` (`phase_start/1`) — assembles `# Tools`/`# Skills`/`# Service Status`/`# Prompt` into the kickoff query. Lines 44-52 (tool and skill section building) are removed. The `non_interactive` auto-injection at lines 34-40 moves to the phase-extras path.
- `lib/destila/ai/conversation.ex:240-257` (`handle_session_strategy/2`) — stops ClaudeSession and creates new `AI.Session` when `:new`. Logic becomes "if current phase's group != previous phase's group, cut a new session," driven off `ws.current_phase` and the previous-phase group from `groups/0`.
- `lib/destila/workers/ai_query_worker.ex:22-43` — calls `SessionConfig.session_opts_for_workflow/3`, then `ClaudeSession.for_workflow_session/2`, then `query_streaming/3`. No changes expected; it already opaquely forwards the opts keyword list.
- `lib/destila/ai/claude_session.ex:145-194` (`init/1`) — forwards all keyword opts to `ClaudeCode.start_link/1` via `Keyword.put_new`. Already supports `:system_prompt` since it's opaque; no changes expected.
- `deps/claude_code/lib/claude_code/options.ex:361` — `:system_prompt` is a supported ClaudeCode session-level option that **replaces the default system prompt**. This is exactly the shape we want.
- `priv/skills/code_quality.md`, `priv/skills/non_interactive.md` — the two existing skills. Neither has `always: true`, so `always_included/0` currently returns `[]`.

### Institutional Learnings

- `docs/plans/2026-04-06-refactor-move-session-opts-to-session-config-plan.md` — earlier extraction that kept `SessionConfig` as the single place that maps phase definitions to `ClaudeCode.start_link/1` opts. Keep that invariant: `SessionConfig` owns the transformation, not callers.
- `docs/plans/2026-04-13-feat-skills-system-plan.md` — original skills system. The dedup semantics in `assemble_skills/1` were chosen specifically so that skills could be listed at multiple layers without duplication; this plan deliberately preserves that property at group + phase-extra layers.
- `docs/plans/2026-04-05-refactor-extract-ai-conversation-module-plan.md` — split `phase_start/1` and friends out of the LiveView. Keeps the convention that `Conversation` is the one place that decides what goes into the kickoff message body.
- `docs/plans/2026-03-29-restructure-workflow-system-plan.md` — the prior structural refactor that introduced `%Phase{}` structs and the `Workflow` behaviour. The new `AISessionGroup` lives one level above `%Phase{}` in the same declarative-config style.

### External References

None needed. All affected modules are first-party. The ClaudeCode SDK option shape was confirmed locally in `deps/claude_code/lib/claude_code/options.ex`.

## Key Technical Decisions

- **Group is a struct, not a macro DSL.** `AISessionGroup` is a plain struct with `name`, `skills`, `allowed_tools`, and `phases` fields. Workflow modules build it in `groups/0` with ordinary Elixir. **Rationale:** mirrors the existing `%Phase{}` style and keeps `Workflow` a thin behaviour; no new compile-time machinery to debug.
- **`phases/0` is derived, not defined.** The `Workflow` `__using__` macro injects a default `def phases, do: Enum.flat_map(groups(), & &1.phases)`, still marked `defoverridable`. All three workflows stop defining `phases/0` directly. **Rationale:** keeps `total_phases/0`, `phase_name/1`, `phase_columns/0`, and all 10+ existing `Workflows.phase_name/phases/phase_columns` call sites working without touching any of them.
- **System prompt = assembled skills, passed at session start.** `SessionConfig` calls `Skills.assemble_skills(group.skills)` and puts the string under `:system_prompt` in the ClaudeCode opts. If the string is empty (no skills), the key is omitted so CLI defaults apply. **Rationale:** this is what the refactor is for — skills act as the real system prompt of the AI session they belong to.
- **Per-phase extra skills are body content only.** `Conversation.phase_start/1` builds the body with `# Prompt\n\n<Skills (additional) + initial_prompt>`. The phase-extra skills pass through `Skills.assemble_skills_excluding(phase_skills, group_skills)` — a new helper that preserves dedup semantics *and* excludes whatever the group already contributed. **Rationale:** system prompt is fixed for the session lifetime, but the same phase may want a reminder skill; the message body is the only surface where per-phase skills can act.
- **Group boundary detection uses `ws.current_phase - 1` on the flattened list.** A helper `group_for_phase(workflow_type, phase_number)` locates the group containing that 1-based index. **"Group boundary" is defined operationally as**: the step of entering a phase whose group differs from the group of phase `ws.current_phase - 1`. When `ws.current_phase == 1`, there is no previous phase and **no boundary action fires** — the bootstrap path (`ensure_ai_session/1` in `Conversation.phase_start/1`) is solely responsible for creating the first `AI.Session` if one doesn't already exist. Otherwise (phase_number > 1), a new session is cut iff `group_for_phase(wt, phase_number) != group_for_phase(wt, phase_number - 1)`. **Rationale:** makes boundary detection a pure function of workflow config + phase number with a clear bootstrap carve-out, and avoids ever cutting a redundant session on phase 1.
- **Location of `group_for_phase/2`: `Destila.Workflows` dispatcher.** Not the macro, not the struct module. **Rationale:** keeps the API symmetric with `Destila.Workflows.phases/1` and `Destila.Workflows.groups/1`, and avoids threading workflow-module lookups through every caller.
- **Remove `# Tools` section from the body entirely.** Tool descriptions are already forwarded to the SDK via `:allowed_tools`; duplicating them as markdown in the first user message was a legacy workaround before SDK-level tool scoping was reliable. **Rationale:** less noise in the kickoff message, fewer tokens, one source of truth for tool scope.
- **Remove the vestigial `session_strategy: {_action, opts}` pattern.** No workflow has ever used the tuple form. **Rationale:** dead code.

## Open Questions

### Resolved During Planning

- **Does ClaudeCode SDK support `:system_prompt` at `start_link/1`?** Yes — `deps/claude_code/lib/claude_code/options.ex:361` lists it as an option, with behavior "Replace the entire default system prompt." Exactly the shape we need.
- **What happens to a live ClaudeSession resumed via `:resume` with an old-shape system prompt?** The SDK retains the original session's system prompt on resume regardless of new opts. Per the brief, that's acceptable — only newly started groups see the new shape. No shim needed.
- **Do we need a DB migration for `current_phase`?** No. `current_phase` stays a 1-based integer over the flattened phase list; the flattened ordering for all three workflows is identical to today.
- **Where does auto-injection of `non_interactive` skill live?** In the phase-extras body path. The group's `system_prompt` must not depend on per-phase flags because it's fixed for the session lifetime, but a group can contain a mix of interactive and non-interactive phases (the Implement workflow's Group 2 does).
- **Should `Workflow.groups/0` be a `@callback`?** Yes. `phases/0` demotes to a macro-generated derivative. `groups/0` becomes the sole declaration surface for workflow phase structure.
- **Do we add unit tests for `SessionConfig`?** Yes — there are none today. With `SessionConfig` gaining responsibility for the SDK `system_prompt`, its contract needs direct coverage rather than relying on indirect LiveView tests.
- **Where does `group_for_phase/2` live?** `Destila.Workflows` dispatcher module. See Key Technical Decisions for rationale.
- **What does `Skills.assemble_skills_excluding/2` return when all skills are excluded?** Returns `""` (the empty string), matching `assemble_skills/1`'s empty-list behavior. Callers are responsible for skipping the "# Skills (additional)" header when the rendered string is empty — see Unit 5 approach.
- **What's the signature of `AI.create_ai_session/1`?** Accepts a map with `:workflow_session_id` (required) and optional `:worktree_path`, `:claude_session_id` — confirmed at `lib/destila/ai.ex:59-62` and `lib/destila/ai/session.ex:15-22`. Existing `Conversation.handle_session_strategy/2` at `lib/destila/ai/conversation.ex:249-252` already calls it with exactly the `%{workflow_session_id: ws.id, worktree_path: worktree_path}` shape this plan adopts.
- **Does ClaudeSession's `:allowed_tools` fallback still apply when the group sets `[]`?** Yes — `SessionConfig` only puts `:allowed_tools` in opts when the list is non-empty (mirroring today's `session_config.ex:54`), so `ClaudeSession.init/1`'s `@default_allowed_tools` still applies for groups that don't specify tools. Preserved deliberately; covered by a Unit 6 regression test.

### Deferred to Implementation

- **Whether to retain or delete `SessionConfig.merge_phase_opts/2`.** Today it deep-merges MCP server maps. After this refactor its only caller (`session_opts_for_workflow/3`) no longer passes phase-level opts. Grep the whole repo before the merge; if no other caller exists, delete it. If it's referenced from tests or elsewhere, keep it as-is.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

### Data shape

```
%AISessionGroup{
  name: String.t(),
  skills: [String.t()],          # group-level skills -> SDK system_prompt
  allowed_tools: [String.t()],   # SDK :allowed_tools at session start
  phases: [%Phase{}]             # ordered; at least one
}

%Phase{
  name: String.t(),
  initial_prompt: (WorkflowSession.t() -> String.t()),  # renamed from :system_prompt
  non_interactive: boolean(),    # default false
  skills: [String.t()]           # optional per-phase extras; default []
  # removed: :session_strategy, :allowed_tools, :system_prompt
}
```

### Workflow definition shape (illustrative)

```
ImplementGeneralPromptWorkflow.groups/0 =>
  [
    %AISessionGroup{
      name: "Planning",
      skills: ["code_quality"],
      allowed_tools: @implementation_tools,
      phases: [
        %Phase{name: "Generate Plan",   initial_prompt: ..., non_interactive: true},
        %Phase{name: "Deepen Plan",     initial_prompt: ..., non_interactive: true}
      ]
    },
    %AISessionGroup{
      name: "Implementation",
      skills: ["code_quality"],
      allowed_tools: @implementation_tools,
      phases: [
        %Phase{name: "Work",           initial_prompt: ..., non_interactive: true},
        %Phase{name: "Review",         initial_prompt: ..., non_interactive: true},
        %Phase{name: "Browser Tests",  initial_prompt: ..., non_interactive: true},
        %Phase{name: "Feature Video",  initial_prompt: ..., non_interactive: true},
        %Phase{name: "Adjustments",    initial_prompt: ...}
      ]
    }
  ]
```

### Flow at phase start (illustrative)

```
phase_start(ws):
  phase_num        = ws.current_phase
  group            = group_for_phase(ws.workflow_type, phase_num)
  phase            = Enum.at(group.phases, index_within_group)

  # Group-boundary cut: only fires on phase_num > 1 when the group changes.
  # Phase 1 leaves bootstrap to ensure_ai_session/1 below.
  if phase_num > 1:
    prev_group = group_for_phase(ws.workflow_type, phase_num - 1)
    if group != prev_group:
      prev_wt_path = current_ai_session(ws).worktree_path
      stop_claude_session(ws.id)
      create_ai_session(ws.id, worktree_path: prev_wt_path)

  session = ensure_ai_session(ws)   # bootstrap on phase 1, or resume otherwise
  body_skills = phase.skills ++ (if phase.non_interactive, do: ["non_interactive"], else: [])
  extras_body = Skills.assemble_skills_excluding(body_skills, group.skills)

  body = ["# Service Status\n\n..." if present,
          "# Skills (additional)\n\n#{extras_body}" if non-empty,
          "# Prompt\n\n#{phase.initial_prompt.(ws)}"]
         |> reject(nil) |> join("\n\n")

  enqueue_ai_worker(ws, phase_num, body)

session_opts_for_workflow(ws, phase, base_opts):
  group  = group_for_phase(ws.workflow_type, phase)
  skills = Skills.assemble_skills(group.skills)
  opts = base_opts
       |> put_if_present(:system_prompt, skills)
       |> put_if_non_empty(:allowed_tools, group.allowed_tools)
       |> put_if_present(:resume, ai_session.claude_session_id)
       |> put_if_present(:cwd, ai_session.worktree_path)
       |> put(:ai_session_id, ai_session.id)
```

## Implementation Units

- [ ] **Unit 1: Introduce `AISessionGroup` struct and update `Phase`**

**Goal:** Add the new struct and make the minimal compile-time changes to `Phase`.

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Create: `lib/destila/workflows/ai_session_group.ex`
- Modify: `lib/destila/workflows/phase.ex`
- Test: `test/destila/workflow_test.exs` (struct-shape assertions; see Unit 6)

**Approach:**
- `AISessionGroup` is a plain struct with `@enforce_keys [:name, :phases]`, and default-valued `skills: []` and `allowed_tools: []`. `phases` is a list of `%Phase{}`.
- In `Phase`, rename `:system_prompt` → `:initial_prompt` (keep it in `@enforce_keys`), drop `:session_strategy`, drop `:allowed_tools`, keep `:skills` with default `[]` and `:non_interactive` with default `false`.
- Update both modules' `@moduledoc` to describe the new role.

**Patterns to follow:**
- `%Phase{}` style: `@enforce_keys`, `defstruct` with defaults, no typespecs (matching current module).

**Test scenarios:**
- Happy path: building `%AISessionGroup{name: "g", phases: [%Phase{name: "p", initial_prompt: fn _ -> "" end}]}` succeeds.
- Edge case: enforcing keys — building a `Phase` without `:initial_prompt` raises `ArgumentError`; building an `AISessionGroup` without `:phases` or `:name` raises `ArgumentError`.
- Defaults: new `Phase` has `skills: []` and `non_interactive: false`; new `AISessionGroup` has `skills: []` and `allowed_tools: []`.

**Verification:**
- `mix compile --warnings-as-errors` passes after all dependent modules are updated (may fail standalone — chain-verify with Unit 2-4).
- Neither struct has `:session_strategy`, `:allowed_tools`, or `:system_prompt` on `Phase`.

---

- [ ] **Unit 2: Update the `Workflow` behaviour and macro to own `groups/0`**

**Goal:** Make `groups/0` the sole declaration surface; generate `phases/0` from it by flattening.

**Requirements:** R1

**Dependencies:** Unit 1

**Files:**
- Modify: `lib/destila/workflows/workflow.ex`
- Test: `test/destila/workflow_test.exs` (macro flattening)

**Approach:**
- Replace `@callback phases() :: [phase_definition()]` with `@callback groups() :: [group_definition()]` where `group_definition` is `%AISessionGroup{}`.
- In `__using__`: generate `def phases, do: Enum.flat_map(groups(), & &1.phases)` and mark it `defoverridable`. Keep `total_phases/0`, `phase_name/1`, `phase_columns/0` generated exactly as today (they read `phases/0`, so they keep working).
- Update the `@moduledoc` example to show a `groups/0` definition instead of `phases/0`.

**Patterns to follow:**
- Existing `__using__` pattern in `lib/destila/workflows/workflow.ex:44-70`.

**Test scenarios:**
- Happy path: a minimal `use Destila.Workflows.Workflow` module that defines `groups/0` exposes a flattened `phases/0` in group+phase order.
- Integration: `total_phases/0`, `phase_name/1`, and `phase_columns/0` on the minimal module produce the expected integer, name string, and tuple list — proving the generated code still reads `phases/0` correctly.
- Edge case: a workflow with two groups of differing lengths flattens correctly (3 + 2 = 5 phases, columns ends with `{:done, "Done"}`).

**Verification:**
- The behaviour now requires `groups/0`; any module that only defines `phases/0` no longer compiles (confirmed after Unit 3 lands).

---

- [ ] **Unit 3: Rewrite the three workflow modules to define `groups/0`**

**Goal:** Map each existing workflow to its new group/phase shape, identical user-visible behavior.

**Requirements:** R2, R8

**Dependencies:** Unit 1, Unit 2

**Files:**
- Modify: `lib/destila/workflows/brainstorm_idea_workflow.ex`
- Modify: `lib/destila/workflows/code_chat_workflow.ex`
- Modify: `lib/destila/workflows/implement_general_prompt_workflow.ex`
- Test: `test/destila/workflow_test.exs` (group-shape assertions; see Unit 6)

**Approach:**
- `BrainstormIdeaWorkflow`: one `%AISessionGroup{name: "Brainstorm", skills: [], allowed_tools: [], phases: [...4 existing phases with :initial_prompt...]}`. No tools/skills moved, since the original phases had none.
- `CodeChatWorkflow`: one `%AISessionGroup{name: "Chat", skills: ["code_quality"], allowed_tools: @chat_tools, phases: [%Phase{name: "Chat", initial_prompt: &chat_prompt/1}]}`. Remove `:allowed_tools` and `:skills` from the phase.
- `ImplementGeneralPromptWorkflow`: two groups.
  - Group 1 (`name: "Planning"`): `skills: ["code_quality"]`, `allowed_tools: @implementation_tools`, phases `Generate Plan` and `Deepen Plan` (both `non_interactive: true`). The `code_quality` skill on Generate Plan is absorbed into the group; the individual phase's `:skills` becomes `[]`.
  - Group 2 (`name: "Implementation"`): `skills: ["code_quality"]`, `allowed_tools: @implementation_tools`, phases `Work`, `Review`, `Browser Tests`, `Feature Video` (all `non_interactive: true`), and `Adjustments` (interactive).
- All `system_prompt:` field references in the three files must become `initial_prompt:`. No prompt-function bodies change.
- Each module deletes its `def phases do ... end`.

**Patterns to follow:**
- Current module layout — module attribute for tool lists at the top, `use Destila.Workflows.Workflow`, then `alias`, then `def groups do ... end`, then metadata functions, then private prompt functions.

**Test scenarios:**
- **Happy path** (BrainstormIdeaWorkflow): `groups/0` returns one `%AISessionGroup{}` named `"Brainstorm"` with empty `skills` and `allowed_tools`, and phases named exactly `["Task Description", "Gherkin Review", "Technical Concerns", "Prompt Generation"]` in order.
- **Happy path** (CodeChatWorkflow): `groups/0` returns one group with `skills: ["code_quality"]`, `allowed_tools: @chat_tools` (11 strings), and phases `[%Phase{name: "Chat", ...}]`; that phase has `skills: []` (moved to group) and no `:allowed_tools` field at all.
- **Happy path** (ImplementGeneralPromptWorkflow): `groups/0` returns exactly 2 groups. Group 1 is `"Planning"` with 2 phases `["Generate Plan", "Deepen Plan"]`; Group 2 is `"Implementation"` with 5 phases `["Work", "Review", "Browser Tests", "Feature Video", "Adjustments"]`. Both groups have `skills: ["code_quality"]` and `allowed_tools: @implementation_tools`.
- **Integration**: `ImplementGeneralPromptWorkflow.phases()` (generated) flattens to exactly 7 phases in the order Generate Plan, Deepen Plan, Work, Review, Browser Tests, Feature Video, Adjustments, matching today.
- **Integration**: `ImplementGeneralPromptWorkflow.total_phases() == 7`, `BrainstormIdeaWorkflow.total_phases() == 4`, `CodeChatWorkflow.total_phases() == 1`.
- **Integration**: `phase_name(3)` on the Implement workflow still returns `"Work"`, and `phase_columns/0` on it still ends with `{:done, "Done"}` after 7 phase columns.
- **Edge case**: none of the phases exposes `:session_strategy` or `:allowed_tools` (struct-field-shape check); `:non_interactive` is `true` for the expected autonomous phases and `false` for `Task Description`, `Gherkin Review`, `Technical Concerns`, `Prompt Generation`, `Chat`, and `Adjustments`.

**Verification:**
- `mix compile --warnings-as-errors` passes.
- Existing Gherkin-linked LiveView tests (see Unit 7) still pass unmodified.

---

- [ ] **Unit 4: Thread `groups/0` through the dispatcher and add group resolution**

**Goal:** Expose `groups/0` and a `group_for_phase/2` helper on `Destila.Workflows`; wire skill assembly to accept a "skip set."

**Requirements:** R1, R7

**Dependencies:** Unit 2

**Files:**
- Modify: `lib/destila/workflows.ex`
- Modify: `lib/destila/workflows/skills.ex`
- Test: `test/destila/workflow_test.exs` (dispatcher); `test/destila/workflows/skills_test.exs` (skills)

**Approach:**
- In `Destila.Workflows`, add `def groups(workflow_type), do: workflow_module(workflow_type).groups()` alongside the existing `phases/1`.
- Add `def group_for_phase(workflow_type, phase_number)` that walks `groups(workflow_type)` summing each group's `length(phases)`, returning the `%AISessionGroup{}` whose cumulative range contains `phase_number` (1-based). Return `nil` if out of range.
- In `Destila.Workflows.Skills`, add `def assemble_skills_excluding(phase_skills, exclude_identifiers)` that mirrors `assemble_skills/1` but drops any resolved skill whose identifier is in `exclude_identifiers`. Preserve dedup semantics (`always_included() ++ by_identifiers(...)` then `Enum.uniq_by/2`), apply the exclusion *after* dedup. **Returns `""` when no skills remain after filtering** (matching `assemble_skills/1`'s empty-input behavior). Callers must skip the "# Skills (additional)" header when the returned string is empty; see Unit 5.

**Patterns to follow:**
- Dispatcher delegation pattern at `lib/destila/workflows.ex:71-76`.
- `Skills.assemble_skills/1` structure at `lib/destila/workflows/skills.ex:33-40`.

**Test scenarios:**
- Happy path (dispatcher): `Destila.Workflows.groups(:implement_general_prompt)` returns the same 2-group list `ImplementGeneralPromptWorkflow.groups()` returns.
- Happy path (group_for_phase): `group_for_phase(:implement_general_prompt, 1)` returns Group 1; `group_for_phase(:implement_general_prompt, 2)` returns Group 1; `group_for_phase(:implement_general_prompt, 3)` returns Group 2; `group_for_phase(:implement_general_prompt, 7)` returns Group 2.
- Edge case (group_for_phase): `group_for_phase(:implement_general_prompt, 0)` returns `nil`; `group_for_phase(:implement_general_prompt, 8)` returns `nil`.
- Happy path (assemble_skills_excluding): given group-level `["code_quality"]` and phase extras `["non_interactive", "code_quality"]`, `assemble_skills_excluding(["non_interactive", "code_quality"], ["code_quality"])` renders only the `## Non-Interactive Phase` section (no duplicate `## Code Quality`).
- Edge case (assemble_skills_excluding): empty `phase_skills` returns `""`; empty `exclude_identifiers` behaves identically to `assemble_skills/1`.
- Integration (skills): when `priv/skills/` contains both `code_quality.md` (always: false) and `non_interactive.md` (always: false), no skill is auto-injected beyond what the caller passes — confirming `always_included/0` behavior is not accidentally changed.

**Verification:**
- `Destila.Workflows.phases/1` still returns a flat list; no callers need to change.
- `Destila.Workflows.groups/1` and `group_for_phase/2` are callable and return the expected shapes.

---

- [ ] **Unit 5: Wire the runtime to groups — `SessionConfig` and `Conversation`**

**Goal:** Make `SessionConfig` pass the group's skills as `:system_prompt` and the group's tools as `:allowed_tools`; make `Conversation.phase_start/1` cut AI sessions at group boundaries and stop inlining `# Tools`/`# Skills` into the kickoff body.

**Requirements:** R3, R4, R5, R6, R7

**Dependencies:** Unit 1, Unit 3, Unit 4

**Files:**
- Modify: `lib/destila/ai/session_config.ex`
- Modify: `lib/destila/ai/conversation.ex`
- Test: `test/destila/ai/session_config_test.exs` (new — see Unit 6); `test/destila/ai/conversation_test.exs` (extend — see Unit 6)

**Approach:**
- In `SessionConfig.session_opts_for_workflow/3`:
  - Resolve the group via `Destila.Workflows.group_for_phase(workflow_session.workflow_type, phase)`.
  - Build `system_prompt = Skills.assemble_skills(group.skills)`. If non-empty, `Keyword.put(opts, :system_prompt, system_prompt)`; otherwise leave it out.
  - Replace the current phase-level `:allowed_tools` branch with `if group.allowed_tools != [], do: Keyword.put(opts, :allowed_tools, group.allowed_tools)`.
  - Delete the `%Destila.Workflows.Phase{session_strategy: {_action, opts}}` branch and the `merge_phase_opts(opts, strategy_opts)` call (strategy_opts was always `[]` in practice; keep `merge_phase_opts/2` if unused elsewhere only if it's still referenced — otherwise remove it too). The final return becomes just `opts`.
  - Preserve existing `:ai_session_id`, `:resume`, `:cwd` forwarding.
- In `Conversation.phase_start/1`:
  - Remove the `tool_section` and `skill_section` blocks (conversation.ex:44-52).
  - Replace `handle_session_strategy(ws, phase_number)` call (conversation.ex:30) with a new `maybe_cut_group_boundary(ws, phase_number)` step. The logic:
    - If `phase_number == 1`: **do nothing**. The bootstrap path (`ensure_ai_session/1` further down in `phase_start/1`) is solely responsible for creating the first `AI.Session` if none exists.
    - If `phase_number > 1`: compute `group = Workflows.group_for_phase(ws.workflow_type, phase_number)` and `prev_group = Workflows.group_for_phase(ws.workflow_type, phase_number - 1)`. If `group != prev_group`, read the current `AI.Session.worktree_path`, call `AI.ClaudeSession.stop_for_workflow_session(ws.id)`, and `AI.create_ai_session(%{workflow_session_id: ws.id, worktree_path: previous_worktree_path})`. If `group == prev_group`, do nothing — the existing `AI.Session` and `ClaudeSession` are reused via `ensure_ai_session/1`'s get-or-create semantics.
    - This is exactly the behavior today's `handle_session_strategy(:new)` implements for the Work phase, generalized to any group transition.
  - Build `body_skills = if non_interactive, do: Enum.uniq(["non_interactive" | phase_skills]), else: phase_skills`. Render via `Skills.assemble_skills_excluding(body_skills, group.skills)`. If non-empty, prepend `# Skills (additional)\n\n<rendered>` to the body sections list, **before** `# Prompt`.
  - The final body becomes: `[service_section, skills_extra_section, "# Prompt\n\n#{phase_prompt}"] |> reject(nil) |> Enum.join("\n\n")`.
  - Delete `handle_session_strategy/2` (lines 232-257) and update docs/comments.
  - Update `get_phase/2` to destructure `%{initial_prompt: prompt_fn, skills: phase_skills, non_interactive: non_interactive}` from the phase; drop the `allowed_tools` key.
- Update `phase_start/1`'s destructure on conversation.ex:23-28 accordingly.

**Execution note:** Implement the `SessionConfig` changes test-first (Unit 6 specifies the test shape) since its contract is what `ClaudeSession` depends on at runtime. `Conversation.phase_start/1` can follow.

**Technical design:** *(optional — see "Flow at phase start" and `session_opts_for_workflow` sketches in §High-Level Technical Design.)*

**Patterns to follow:**
- Existing `SessionConfig` structure — a single function that returns a keyword list, with conditional `Keyword.put/3` per key.
- Existing `phase_start/1` structure — `sections` list then `Enum.reject(&is_nil/1) |> Enum.join("\n\n")`.

**Test scenarios:**
- See Unit 6 for the full test plan. This unit's code must make those tests pass.

**Verification:**
- `mix compile --warnings-as-errors` passes.
- Grep confirms `:session_strategy` appears nowhere in `lib/`.
- Grep confirms `# Tools\\n\\n` and `# Skills\\n\\n` (without `(additional)`) appear nowhere in the emitted kickoff body code path.
- `mix test test/destila/ai/session_config_test.exs test/destila/ai/conversation_test.exs` passes.

---

- [ ] **Unit 6: Unit tests for workflow shape, `SessionConfig`, and `Conversation.phase_start`**

**Goal:** Directly cover the new contracts that LiveView tests only touch indirectly.

**Requirements:** R1, R3, R4, R5, R6, R7, R8

**Dependencies:** Unit 3, Unit 4, Unit 5

**Files:**
- Modify: `test/destila/workflow_test.exs`
- Create: `test/destila/ai/session_config_test.exs`
- Modify: `test/destila/ai/conversation_test.exs`

**Approach:**
- In `test/destila/workflow_test.exs`: keep the existing `total_phases/0`, `phase_name/1`, `phase_columns/0`, `creation_label/0`, `source_metadata_key/0` assertions. **Delete** the two `session_strategy` tests (`"session_strategy defaults to :resume for all phases"` and the Work-phase `:new` test). **Add** `describe "groups/0"` blocks for each of the three workflow modules that assert: group count, group names, group `skills` / `allowed_tools`, ordered phase names within each group, and that the flattened `phases()` matches today's ordering exactly.
- Create `test/destila/ai/session_config_test.exs`. Use the same fixtures pattern as `test/destila/ai/conversation_test.exs` (insert a `WorkflowSession` and `AI.Session`, drive `session_opts_for_workflow/3`). Cover:
  - For `:brainstorm_idea` phase 1: `:system_prompt` key **is not present** (group has no skills) and `:allowed_tools` key **is not present** (group has no tools); `:ai_session_id`, `:resume` (when `claude_session_id` set), `:cwd` (when `worktree_path` set) are forwarded as today.
  - For `:code_chat` phase 1: `:system_prompt` is the rendered string for `["code_quality"]` (`=~ "## Code Quality"`); `:allowed_tools` equals the `@chat_tools` list.
  - For `:implement_general_prompt` phase 1 (Planning group): `:system_prompt =~ "## Code Quality"`, `:allowed_tools == @implementation_tools`.
  - For `:implement_general_prompt` phase 3 (Implementation group): same `system_prompt` content and same tools (distinct group instances, but identical skill identifiers).
  - Regression: no `:session_strategy` key ever appears in the returned opts.
  - Regression: `merge_phase_opts/2` behavior (if retained) is unchanged — MCP map-merge still works.
- In `test/destila/ai/conversation_test.exs`: keep all existing `handle_ai_error/2` and `handle_ai_result/2` tests. **Add** a new `describe "phase_start/1 kickoff body"` block using the same `create_session` helper. Since `phase_start/1` enqueues an Oban job with `%{"query" => query}`, assert against the enqueued job's args:
  - For `:brainstorm_idea` phase 1 (no group skills, interactive): query contains `"# Prompt\\n\\n"` and does **not** contain `"# Tools"`, `"# Skills\\n\\n"` (standalone), or `"# Skills (additional)"`.
  - For `:code_chat` phase 1 (group skills `["code_quality"]`, no phase extras): query does **not** contain `"# Skills (additional)"` (the group already covers `code_quality`); does **not** contain `"# Tools"`.
  - For `:implement_general_prompt` phase 1 (non-interactive, group skills `["code_quality"]`): query contains `"# Skills (additional)"` with the `## Non-Interactive Phase` body (because `non_interactive` skill auto-injects as a phase extra and is not in the group's set); does **not** duplicate `## Code Quality`.
- **Add** a new `describe "phase_start/1 group boundary"` block:
  - Given a `WorkflowSession` for `:implement_general_prompt` with `current_phase: 3` (Work — Group 2) and an existing `AI.Session` with `worktree_path: "/tmp/wt"` and `claude_session_id: "abc"`, calling `phase_start/1` stops the previous `ClaudeSession` (mock via `Mox` or inspect Registry state — whichever the repo already uses), inserts a new `AI.Session` with the same `worktree_path`, and leaves `claude_session_id` nil on the new session. Use `Ecto` to assert two `AI.Session` rows exist for the workflow session after the call.
  - Regression: calling `phase_start/1` for `current_phase: 2` (Deepen Plan — Group 1) with an existing Group 1 session does **not** create a new `AI.Session` row.
  - Bootstrap: calling `phase_start/1` for `current_phase: 1` on a brand-new `WorkflowSession` (no `AI.Session` yet) creates exactly **one** `AI.Session` row (via `ensure_ai_session/1` bootstrap) and does **not** stop any `ClaudeSession` — proving the phase-1 carve-out doesn't accidentally fire a redundant group-boundary cut.

**Patterns to follow:**
- `test/destila/ai/conversation_test.exs` fixture pattern (`create_session`, `DestilaWeb.ConnCase, async: false`).
- `test/destila/workflows/skills_test.exs` for synchronous unit tests (`use ExUnit.Case, async: true`).
- `test/destila/workflow_test.exs` for `describe`-per-workflow structure.

**Test scenarios:**
- Covered inline above.

**Verification:**
- `mix test test/destila/workflow_test.exs test/destila/ai/session_config_test.exs test/destila/ai/conversation_test.exs test/destila/workflows/skills_test.exs` passes.
- Deleting the two removed fields (`:session_strategy`, `:allowed_tools`) from `Phase` would cause exactly the new tests to exercise the new assertions, not pass-by-accident.

---

- [ ] **Unit 7: Validate existing Gherkin-linked LiveView tests and any other consumers**

**Goal:** Confirm no user-observable change — sidebar AI-session counts, phase stepper, crafting board columns, chat header.

**Requirements:** R8, R9

**Dependencies:** Unit 5

**Files:**
- Verify (no edits expected): `test/destila_web/live/brainstorm_idea_workflow_live_test.exs`
- Verify (no edits expected): `test/destila_web/live/code_chat_workflow_live_test.exs`
- Verify (no edits expected): `test/destila_web/live/implement_general_prompt_workflow_live_test.exs`
- Verify (no edits expected): `test/destila_web/live/ai_session_sidebar_live_test.exs`
- Verify (no edits expected): `test/destila_web/live/ai_session_detail_live_test.exs`
- Verify (no edits expected): `test/destila/executions_test.exs`, `test/destila_web/live/crafting_board_live_test.exs` if present — they hit `phase_columns/0`, `phase_name/1`, `total_phases/0`.

**Approach:**
- Run the full `mix test` suite. No test file should require edits; if a LiveView test fails, the root cause is almost certainly in Unit 3 (workflow shape mismatch) or Unit 5 (runtime wiring). Do **not** fix by weakening tests — trace back to the implementation unit.
- Manually smoke-test the three workflows in `iex -S mix phx.server` only if a test fails whose cause isn't obvious from the diff; the unit tests should cover everything.

**Test scenarios:**
- Test expectation: none — this is a verification unit, no new tests.

**Verification:**
- `mix precommit` succeeds.
- Full `mix test` passes.
- `git grep session_strategy lib/` returns no results.
- `git grep ":system_prompt" lib/destila/workflows/` returns no results (the field is gone; ClaudeCode SDK's `:system_prompt` still shows up in `lib/destila/ai/session_config.ex` and `lib/destila/ai.ex`, both expected).

## System-Wide Impact

- **Interaction graph:** `Workflows.phases/1` remains the compatibility seam. All 10+ call sites (`lib/destila/workflows.ex:71-76`, `lib/destila/executions.ex:69`, `lib/destila_web/live/workflow_runner_live.ex:48/737/740`, `lib/destila_web/live/crafting_board_live.ex:139`, `lib/destila_web/live/ai_session_detail_live.ex:322/429`, `lib/destila_web/components/chat_components.ex:58/68/337`, `lib/destila_web/components/board_components.ex:136-138/177`, `lib/destila_web/components/ai_session_debug_components.ex:41/52`) keep their current interface. `phase_start/1` is the only other runtime entry point exercised; its signature is unchanged.
- **Error propagation:** `phase_start/1` still enqueues an Oban job on success. `SessionConfig.session_opts_for_workflow/3` is a pure function — no new failure modes. If `group_for_phase/2` returns `nil` (shouldn't happen for a valid `current_phase`), the caller will raise; add a defensive `Map.fetch!`-style error at the dispatcher so misconfigurations surface loudly rather than silently producing empty opts.
- **State lifecycle risks:** `AI.Session` rows are created at each group boundary — same as today's `:session_strategy: :new`. The new logic must compute the boundary correctly even when `current_phase == 1` (no previous phase). The bootstrap path (`ensure_ai_session/1`) must not double-insert when the first group's first phase runs.
- **API surface parity:** The `Workflow` behaviour now requires `groups/0` instead of `phases/0`. Any out-of-tree workflow modules would break, but there are none — the three in-tree modules are the only implementers.
- **Integration coverage:** The boundary-cut behavior (Unit 6, phase_start group-boundary block) is the one place unit tests alone might under-specify; cover both "advance within group (no new session)" and "advance across group (new session carries worktree)" scenarios explicitly.
- **Unchanged invariants:** `workflow_sessions.current_phase` semantics (1-based over the flattened phase list), `WorkflowSession` schema, `AI.Session` schema, ClaudeSession GenServer registry keying, all LiveView assigns and consumers of `phases/1` / `phase_name/2` / `total_phases/1` / `phase_columns/1` — all unchanged.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| A resumed Claude CLI session carries the old message-body skills/tools *and* a newly-passed `:system_prompt` from `start_link`, causing weird overlap. | Per the SDK, `:system_prompt` applies to new sessions; on resume the original system prompt is retained. Brief explicitly accepts this and requires no shim. Document the behavior in the `AISessionGroup` moduledoc. |
| `group_for_phase/2` drifts out of sync with `phases/0` (e.g., someone adds a phase to a group but doesn't run the generator). | `groups/0` is the *source* and `phases/0` is derived; the only way to desync is to override `phases/0` manually. Add a test in Unit 6 that asserts `phases() == Enum.flat_map(groups(), & &1.phases)` for each workflow module. |
| `non_interactive` skill double-renders when a group's skills ever include it. | Today no group will include `non_interactive` in its system prompt (it's a body-only concern). Enforce via Unit 6 test: asserting for the `:implement_general_prompt` phase 1 case that `## Non-Interactive Phase` appears exactly once in the combined (system_prompt + body) payload. |
| Removing `merge_phase_opts/2` breaks a hidden caller that relied on MCP map-merge. | Grep before removal. If any caller outside `session_opts_for_workflow/3` uses it, keep the function; otherwise delete it. |
| The `:allowed_tools` default fallback (`ClaudeSession.@default_allowed_tools`) is accidentally bypassed for a group that intentionally sets `allowed_tools: []`. | Preserve today's behavior: `SessionConfig` only puts `:allowed_tools` in opts when the list is non-empty. Covered by Unit 6's `:brainstorm_idea` test (asserts `:allowed_tools` is absent and fallback applies). |

## Documentation / Operational Notes

- Update `@moduledoc` on `Destila.Workflows.Workflow`, `Destila.Workflows.Phase`, and the new `Destila.Workflows.AISessionGroup` to describe the new shape and show a minimal `groups/0` example.
- Optional: add a brief note in `lib/destila/workflows/implement_general_prompt_workflow.ex` moduledoc that phases 3-7 share an AI session distinct from phases 1-2. Today's docstring already describes the `:new` transition at phase 3 — update the wording to reference groups.
- No rollout, migration, or monitoring changes. All changes are compile-time + runtime-same-shape.

## Sources & References

- Related code: `lib/destila/workflows/phase.ex`, `lib/destila/workflows/workflow.ex`, `lib/destila/workflows.ex`, `lib/destila/workflows/{brainstorm_idea,code_chat,implement_general_prompt}_workflow.ex`, `lib/destila/workflows/skills.ex`, `lib/destila/ai/session_config.ex`, `lib/destila/ai/conversation.ex`, `lib/destila/ai/claude_session.ex`, `lib/destila/workers/ai_query_worker.ex`
- Related tests: `test/destila/workflow_test.exs`, `test/destila/ai/conversation_test.exs`, `test/destila/workflows/skills_test.exs`, `test/destila_web/live/{brainstorm_idea,code_chat,implement_general_prompt}_workflow_live_test.exs`
- Related feature files: `features/implement_general_prompt_workflow.feature:62` ("Phase 3 - AI starts a new session for implementation" — still correct under group-boundary semantics)
- Related plans: `docs/plans/2026-04-06-refactor-move-session-opts-to-session-config-plan.md` (prior SessionConfig extraction), `docs/plans/2026-04-13-feat-skills-system-plan.md` (skills system origin), `docs/plans/2026-03-29-restructure-workflow-system-plan.md` (Phase struct introduction)
- External docs: `deps/claude_code/lib/claude_code/options.ex:361` — `:system_prompt` session-level option semantics (replaces default system prompt)
