---
title: "feat: Implement General Prompt Workflow"
type: feat
date: 2026-03-28
---

# feat: Implement General Prompt Workflow

## Enhancement Summary

**Deepened on:** 2026-03-28
**Sections enhanced:** All major sections
**Review agents used:** architecture-strategist, performance-oracle, security-sentinel, code-simplicity-reviewer, pattern-recognition-specialist, agent-native-reviewer, julik-frontend-races-reviewer, data-integrity-guardian, best-practices-researcher

### Key Simplifications (from review)
1. Merged Phase 1 + Phase 2 into a single `PromptWizardPhase` (eliminates `phase_data` action, preserves one-pre-session-phase invariant)
2. Replaced named `group` field with "latest ai_session" pattern (eliminates 1:N complexity, ~70 LOC saved)
3. Query completed sessions directly instead of via `prompt_generated` metadata (simpler, aligns with read-time derivation principle)
4. Dropped `git commit --amend && git push --force` in Phase 5 (use normal commits for safety and traceability)

### Critical Issues Discovered
1. `AiConversationPhase.handle_info` is dead code — LiveComponents share the parent's process; PubSub only delivers to the LiveView
2. `SetupPhase.update/2` sends `phase_complete` on every re-render when steps are complete — can skip entire phases
3. Non-interactive phases need cancel/abort, `ask_user_question` exclusion, and auto-done on final phase
4. `derive_message_type` assumes last phase = generated prompt — breaks with new 8-phase workflow
5. No timeout on `ClaudeCode.stream` — indefinite resource consumption risk

---

## Overview

Add a new 8-phase workflow called "Implement General Prompt" that takes a user-provided prompt (either selected from an existing session or written manually) and implements it end-to-end through AI-driven planning, coding, reviewing, testing, and video recording. This is the second workflow type in the system, alongside the existing `prompt_chore_task`.

## Problem Statement / Motivation

Currently, the only workflow (`prompt_chore_task`) produces an implementation prompt but stops there. Users must manually hand that prompt to a coding agent and manage the implementation, review, testing, and recording steps. This new workflow closes the loop by taking a prompt and autonomously executing the full implementation pipeline.

## Proposed Solution

An 8-phase workflow with one new pre-session phase type (`PromptWizardPhase`), reuse of `SetupPhase`, and six `AiConversationPhase` instances configured for non-interactive autonomous execution. Two AI session records handle the work: one for planning (Phases 3-4) and one for implementation (Phases 5-8), using a "latest ai_session" lookup pattern.

## Technical Approach

### Architecture

```
Phase 1: PromptWizardPhase (pre-session, LiveComponent)
    ↓ session created, push_navigate to /sessions/:id
Phase 2: SetupPhase (repo sync, worktree, conditional title gen)
    ↓
Phase 3: AiConversationPhase (non-interactive, AI Session A — planning)
Phase 4: AiConversationPhase (non-interactive, resumes AI Session A)
    ↓
Phase 5: AiConversationPhase (non-interactive, AI Session B — new, implementation)
Phase 6: AiConversationPhase (non-interactive, resumes AI Session B)
Phase 7: AiConversationPhase (non-interactive, optional, resumes AI Session B)
Phase 8: AiConversationPhase (non-interactive, resumes AI Session B)
```

**AI Session Strategy (simplified — no `group` field):**
- Phases 3-4 (Planning): `:resume` — creates AI session A on first use, resumes it for Phase 4
- Phase 5 (Work): `:new` — creates AI session B (AI session A stays in DB for message history)
- Phases 6-8: `:resume` — resumes AI session B
- Lookup: `get_ai_session_for_workflow/1` returns the **most recent** AI session (ordered by `inserted_at DESC, LIMIT 1`). When `:new` is triggered, a new `ai_sessions` row is created; the old one remains for message history display.

### Research Insights

**Best Practices (from research):**
- Use parent-owned accumulator map for pre-session data — single `@accumulated` assign, not per-phase state
- Add `unique` constraints to Oban workers: `unique: [keys: [:workflow_session_id, :phase], period: 30, states: [:available, :scheduled, :executing]]`
- Use `{:cancel, reason}` for stale Oban jobs (phase already advanced past this job's phase)
- Prefer parent-only PubSub subscription with `send_update/2` to push data to LiveComponents
- Use scoped PubSub topics (`"workflow_session:#{id}"`) instead of global `"store:updates"` for session views

**Edge Cases (from reviews):**
- `ClaudeCode.stream` has no timeout — add 15-minute timeout for non-interactive phases
- GenServer inactivity timeout message can queue during long `handle_call` — flush in `reset_timer/1`
- `stop_for_workflow_session/1` can race with inactivity timeout — wrap `stop` in `try/catch :exit`
- Force-push is unnecessary on private worktree branches — use normal commits for safety

### Implementation Phases

#### Phase 1: Bug Fixes & Infrastructure (prerequisite)

**1a. Fix SetupPhase duplicate `phase_complete` sends (CRITICAL)**

File: `lib/destila_web/live/phases/setup_phase.ex`

The `update/2` callback sends `phase_complete` on every re-render when all steps are complete. Multiple metadata updates trigger multiple sends, which can skip entire phases.

```elixir
if all_completed?(steps) && !socket.assigns[:phase_complete_sent] do
  send(self(), {:phase_complete, assigns.phase_number, %{}})
end
# Then assign :phase_complete_sent, all_completed?(steps)
```

**1b. Remove dead PubSub code from AiConversationPhase (CRITICAL)**

File: `lib/destila_web/live/phases/ai_conversation_phase.ex`

LiveComponents are not processes — they run inside the parent LiveView's process. The `handle_info` clauses in `AiConversationPhase` are dead code. Remove the PubSub subscription from `mount/1` and all `handle_info` clauses. The component already receives updates via `update/2` when the parent re-renders.

**1c. Fix `derive_message_type` — make it opt-driven**

File: `lib/destila/ai.ex` (line 248-249)

Replace the `phase == workflow_session.total_phases` check with an opt-driven approach:

```elixir
defp derive_message_type(raw, phase, workflow_session) do
  phases = Destila.Workflows.phases(workflow_session.workflow_type)
  phase_opts = case Enum.at(phases, phase - 1) do
    {_mod, opts} -> opts
    nil -> []
  end

  cond do
    Keyword.get(phase_opts, :message_type) == :generated_prompt ->
      {nil, :generated_prompt}
    session = extract_session_action(raw) ->
      # ... existing session action handling
    true ->
      {nil, nil}
  end
end
```

Update `PromptChoreTaskWorkflow` Phase 6 to include `message_type: :generated_prompt` in its opts.

**1d. Extend Session schema for new workflow type**

File: `lib/destila/workflows/session.ex`

Add `:implement_general_prompt` to `Ecto.Enum` values for `workflow_type`.

**1e. DB reset migration**

Since the app is early-stage, reset the database with updated schemas.

**1f. Add phase guard to `handle_info(:phase_complete)` in WorkflowRunnerLive**

File: `lib/destila_web/live/workflow_runner_live.ex`

Prevent stale phase_complete signals from advancing the wrong phase:

```elixir
def handle_info({:phase_complete, phase, _data}, socket)
    when phase == socket.assigns.current_phase do
  # ... advance
end

def handle_info({:phase_complete, _stale_phase, _data}, socket) do
  {:noreply, socket}
end
```

**1g. Enqueue Oban job before broadcasting in `handle_skip_phase`**

File: `lib/destila/workers/ai_query_worker.ex`

Currently, `update_workflow_session` broadcasts before the next Oban job is enqueued, causing a window where the UI shows a spinner with no backing job. Reorder: build prompt, enqueue job, then update session.

**1h. Add Oban unique constraints to workers**

Files: `ai_query_worker.ex`, `setup_worker.ex`, `title_generation_worker.ex`

```elixir
use Oban.Worker, queue: :default, max_attempts: 1,
  unique: [keys: [:workflow_session_id, :phase], period: 30,
           states: [:available, :scheduled, :executing]]
```

#### Phase 2: Non-Interactive AiConversationPhase Support

**2a. Add `:non_interactive` option to AiConversationPhase**

File: `lib/destila_web/live/phases/ai_conversation_phase.ex`

When `opts[:non_interactive]` is true:
- Hide the text input area (`:if` guard checking `!opts[:non_interactive]`)
- Hide structured option buttons (single_select, multi_select, questions)
- Show AI messages as they arrive — the existing message stream with typing indicator IS the progress view
- Add a "Retry" button when `phase_status == :conversing` and `opts[:non_interactive]` (error recovery)
- Add a "Cancel" button when `phase_status == :generating` and `opts[:non_interactive]` (abort runaway AI)

The Cancel button stops the ClaudeSession GenServer and sets `phase_status: :conversing` so the Retry button appears.

**2b. Exclude `ask_user_question` from non-interactive phases**

Non-interactive system prompts must include: "Do NOT call `mcp__destila__ask_user_question` — this phase runs autonomously with no user present."

Additionally, the `@implementation_tools` module attribute should omit `mcp__destila__ask_user_question`:

```elixir
@implementation_tools [
  "Read", "Write", "Edit", "Bash", "Glob", "Grep",
  "mcp__destila__session"
]
```

**2c. Auto-mark-done on final phase `phase_complete`**

File: `lib/destila/workers/ai_query_worker.ex`

In `handle_skip_phase`, when `next_phase > total_phases`, instead of just setting `phase_status: :conversing`, also set `done_at: DateTime.utc_now()` to auto-complete the workflow:

```elixir
if next_phase > total do
  Workflows.update_workflow_session(workflow_session_id, %{
    done_at: DateTime.utc_now(),
    phase_status: nil
  })
end
```

**2d. Add timeout to `ClaudeCode.stream` calls**

File: `lib/destila/ai/claude_session.ex`

Add a `max_turns` limit to non-interactive phase options. Also use a finite GenServer.call timeout (15 minutes) instead of `:infinity`:

```elixir
def query(session, prompt, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, :timer.minutes(15))
  GenServer.call(session, {:query, prompt, opts}, timeout)
end
```

**2e. Flush stale timeout messages in `reset_timer/1`**

File: `lib/destila/ai/claude_session.ex`

```elixir
defp reset_timer(state) do
  Process.cancel_timer(state.timer_ref)
  # Flush any queued timeout message
  receive do
    :inactivity_timeout -> :ok
  after
    0 -> :ok
  end
  timer_ref = schedule_timeout(state.timeout_ms)
  %{state | timer_ref: timer_ref}
end
```

#### Phase 3: AI Session "Latest" Lookup Pattern

**3a. Change `get_ai_session_for_workflow/1` to return the most recent session**

File: `lib/destila/ai.ex`

```elixir
def get_ai_session_for_workflow(workflow_session_id) do
  Repo.one(
    from(s in Session,
      where: s.workflow_session_id == ^workflow_session_id,
      order_by: [desc: s.inserted_at],
      limit: 1
    )
  )
end
```

This returns the most recently created AI session. For `prompt_chore_task` (which only ever has one), behavior is unchanged. For the new workflow, after Phase 5's `:new` strategy creates a second AI session, this returns that new one.

**3b. Update `:new` strategy handling**

File: `lib/destila/workers/ai_query_worker.ex` and `lib/destila_web/live/phases/ai_conversation_phase.ex`

When session strategy is `:new`:
1. Stop the current ClaudeSession GenServer
2. Create a new `ai_sessions` DB record (the old one stays for message history)
3. The new GenServer registers with the same `workflow_session_id` key (old one was stopped)

In `handle_skip_phase`:
```elixir
if action == :new do
  Destila.AI.ClaudeSession.stop_for_workflow_session(workflow_session_id)
  # Create new AI session record
  metadata = Destila.Workflows.get_metadata(workflow_session_id)
  worktree_path = get_in(metadata, ["worktree", "worktree_path"])
  {:ok, _new_session} = Destila.AI.create_ai_session(%{
    workflow_session_id: workflow_session_id,
    worktree_path: worktree_path
  })
end
```

**3c. Update `stop_for_workflow_session` for robustness**

File: `lib/destila/ai/claude_session.ex`

```elixir
def stop_for_workflow_session(workflow_session_id) do
  name = {:via, Registry, {Destila.AI.SessionRegistry, workflow_session_id}}
  case GenServer.whereis(name) do
    nil -> :ok
    pid ->
      try do
        stop(pid)
      catch
        :exit, _ -> :ok
      end
  end
end
```

#### Phase 4: New PromptWizardPhase

**4a. Create `PromptWizardPhase`**

File: `lib/destila_web/live/phases/prompt_wizard_phase.ex`

A single pre-session LiveComponent that combines prompt selection AND project selection on one screen. Follows the same pattern as the existing `WizardPhase`.

**Layout (two sections):**

1. **Prompt section (top)** — Two tabs: "Select from existing" and "Write manually"
   - "Select from existing" shows completed `prompt_chore_task` sessions (query: `done_at IS NOT NULL AND workflow_type = :prompt_chore_task`). Each card shows session title. Clicking selects it. Prompt text is derived from the session's last AI message at read time.
   - "Write manually" shows a textarea for entering a prompt from scratch.

2. **Project section (bottom)** — Same project selection UI as existing `WizardPhase`
   - Pre-selected when an existing session is chosen (from that session's `project_id`)
   - Still allows manual change and inline project creation

**Query function:**

File: `lib/destila/workflows.ex`

```elixir
def list_done_sessions_by_type(workflow_type) do
  from(ws in Session,
    where: ws.workflow_type == ^workflow_type and not is_nil(ws.done_at),
    preload: [:project],
    order_by: [desc: ws.done_at]
  )
  |> Repo.all()
end
```

To extract the prompt text from a completed session, derive it from the last AI message in the final phase (consistent with the project's principle of deriving UI state at read time):

```elixir
def get_generated_prompt_text(workflow_session) do
  ai_session = Destila.AI.get_ai_session_for_workflow(workflow_session.id)
  if ai_session do
    messages = Destila.AI.list_messages(ai_session.id)
    messages
    |> Enum.filter(&(&1.role == :system && &1.phase == workflow_session.total_phases))
    |> List.last()
    |> case do
      nil -> nil
      msg -> String.trim(msg.content)
    end
  end
end
```

**Completion signal:**
```elixir
send(self(), {:phase_complete, phase_number, %{
  action: :session_create,
  project_id: project_id,
  prompt: prompt_text,
  selected_session_id: selected_session_id,
  title_generating: selected_session_id == nil
}})
```

**Extract shared project selection UI:**

File: `lib/destila_web/components/project_components.ex`

Extract the project selection UI from `WizardPhase` into a reusable function component (`project_selector/1`) that both `WizardPhase` and `PromptWizardPhase` can embed. This avoids duplicating ~120 lines of project selection template.

#### Phase 5: Workflow Module

**5a. Create `ImplementGeneralPromptWorkflow`**

File: `lib/destila/workflows/implement_general_prompt_workflow.ex`

```elixir
defmodule Destila.Workflows.ImplementGeneralPromptWorkflow do
  @implementation_tools [
    "Read", "Write", "Edit", "Bash", "Glob", "Grep",
    "mcp__destila__session"
  ]

  @non_interactive_tool_instructions """
  ## Phase Transitions

  When you have completed this phase's work, call `mcp__destila__session`
  with `action: "phase_complete"` and a message summarizing what was done.

  Do NOT use `suggest_phase_complete` — this phase runs autonomously.
  Do NOT call `mcp__destila__ask_user_question` — no user is present.
  """

  def phases do
    [
      {DestilaWeb.Phases.PromptWizardPhase, name: "Prompt & Project"},
      {DestilaWeb.Phases.SetupPhase, name: "Setup"},
      {DestilaWeb.Phases.AiConversationPhase,
        name: "Generate Plan",
        system_prompt: &plan_prompt/1,
        non_interactive: true,
        allowed_tools: @implementation_tools},
      {DestilaWeb.Phases.AiConversationPhase,
        name: "Deepen Plan",
        system_prompt: &deepen_plan_prompt/1,
        non_interactive: true,
        skippable: true,
        allowed_tools: @implementation_tools},
      {DestilaWeb.Phases.AiConversationPhase,
        name: "Work",
        system_prompt: &work_prompt/1,
        non_interactive: true,
        allowed_tools: @implementation_tools},
      {DestilaWeb.Phases.AiConversationPhase,
        name: "Review",
        system_prompt: &review_prompt/1,
        non_interactive: true,
        allowed_tools: @implementation_tools},
      {DestilaWeb.Phases.AiConversationPhase,
        name: "Browser Tests",
        system_prompt: &browser_tests_prompt/1,
        non_interactive: true,
        skippable: true,
        allowed_tools: @implementation_tools},
      {DestilaWeb.Phases.AiConversationPhase,
        name: "Feature Video",
        system_prompt: &feature_video_prompt/1,
        non_interactive: true,
        allowed_tools: @implementation_tools,
        final: true}
    ]
  end

  def total_phases, do: length(phases())

  def phase_name(phase) when is_integer(phase) do
    case Enum.at(phases(), phase - 1) do
      {_mod, opts} -> Keyword.get(opts, :name)
      nil -> nil
    end
  end
  def phase_name(_), do: nil

  def phase_columns do
    columns =
      1..total_phases()
      |> Enum.map(fn n -> {n, phase_name(n)} end)
      |> Enum.reject(fn {_, name} -> is_nil(name) end)

    columns ++ [{:done, "Done"}]
  end

  def default_title, do: "New Implementation"
  def label, do: "Implement a Prompt"
  def description, do: "Take a prompt through planning, coding, review, testing, and recording"
  def icon, do: "hero-rocket-launch"
  def icon_class, do: "text-primary"
  def completion_message, do: "Implementation complete! Plan executed, code reviewed, tests run, and feature recorded."

  # Phases 1-4: resume (single AI session for planning)
  # Phase 5: new (fresh AI session for implementation)
  # Phases 6-8: resume (reuse implementation AI session)
  def session_strategy(5), do: :new
  def session_strategy(_phase), do: :resume

  # --- System Prompts ---

  defp plan_prompt(workflow_session) do
    metadata = Destila.Workflows.get_metadata(workflow_session.id)
    prompt = get_in(metadata, ["prompt", "text"])

    """
    You are an AI planning agent. Your task is to create an implementation plan
    for the following prompt:

    #{prompt}

    Create a detailed plan and save it to `plan.md` in the current directory.
    Then commit and push your changes.

    When done, call `mcp__destila__session` with `action: "phase_complete"`.
    """ <> @non_interactive_tool_instructions
  end

  defp deepen_plan_prompt(_workflow_session) do
    """
    Review the plan in `plan.md`. Evaluate whether a more detailed plan would
    be beneficial for the implementation.

    If yes: enhance the plan with additional detail, commit and push.
    If no: call `mcp__destila__session` with `action: "phase_complete"`
    immediately — the plan is sufficient as-is.
    """ <> @non_interactive_tool_instructions
  end

  defp work_prompt(_workflow_session) do
    """
    Read the plan from `plan.md` in the current directory and implement it
    completely. Commit and push all changes when done.
    """ <> @non_interactive_tool_instructions
  end

  defp review_prompt(_workflow_session) do
    """
    Review the implementation against the plan in `plan.md`. Identify P1 (critical)
    and P2 (important) issues. Fix all P1 and P2 items. Commit and push fixes.
    """ <> @non_interactive_tool_instructions
  end

  defp browser_tests_prompt(_workflow_session) do
    """
    Evaluate whether frontend or backend changes affect existing tests.
    If tests need updating or new tests are needed, run them and fix failures.
    If no test-impacting changes exist, call `mcp__destila__session` with
    `action: "phase_complete"` immediately.
    """ <> @non_interactive_tool_instructions
  end

  defp feature_video_prompt(_workflow_session) do
    """
    Record a feature video walkthrough of the implemented changes.
    Commit and push the video artifact when done.
    """ <> @non_interactive_tool_instructions
  end
end
```

**5b. Register the workflow**

File: `lib/destila/workflows.ex`

```elixir
@workflow_modules %{
  prompt_chore_task: Destila.Workflows.PromptChoreTaskWorkflow,
  implement_general_prompt: Destila.Workflows.ImplementGeneralPromptWorkflow
}
```

**5c. Update board components**

File: `lib/destila_web/components/board_components.ex`

```elixir
def workflow_label(:implement_general_prompt), do: "Implementation"
defp workflow_badge_class(:implement_general_prompt), do: "badge-primary"
```

File: `lib/destila/ai.ex`

```elixir
defp workflow_type_label(:implement_general_prompt), do: "prompt implementation"
```

#### Phase 6: SetupPhase Conditional Title Generation

File: `lib/destila_web/live/phases/setup_phase.ex`

When `ws.title_generating == false` (set during session creation if a source session was selected), skip title generation entirely. Modify `build_steps/2` to omit the title step.

File: `lib/destila_web/live/workflow_runner_live.ex`

In the `:session_create` handler, when `selected_session_id` is present:
1. Look up the source session's title
2. Set it as the new session's title
3. Set `title_generating: false`
4. Store `prompt` as metadata key `"prompt"` with value `%{"text" => prompt}`

### Session Strategy Flow

```
Phase 1 (PromptWizard)  → No AI session needed
Phase 2 (Setup)         → No AI session needed
Phase 3 (Plan)          → :resume → Creates AI session A, starts ClaudeCode
Phase 4 (Deepen Plan)   → :resume → Reuses AI session A's ClaudeCode
Phase 5 (Work)          → :new → Stops ClaudeCode, creates AI session B
Phase 6 (Review)        → :resume → Reuses AI session B's ClaudeCode
Phase 7 (Browser Tests) → :resume → Reuses AI session B's ClaudeCode
Phase 8 (Feature Video) → :resume → Reuses AI session B's ClaudeCode
```

**Deterministic plan file convention:** Phase 3 writes `plan.md` in the worktree root. Phase 5's system prompt reads from that exact path. If `plan.md` does not exist when Phase 5 starts, the AI should report an error via `phase_complete` with an explanatory message.

### Git Operations by Phase

| Phase | Git Operation | Notes |
|-------|--------------|-------|
| 3 — Plan | `git add . && git commit && git push` | New commit |
| 4 — Deepen | `git add . && git commit && git push` | Normal commit (not amend) |
| 5 — Work | `git add . && git commit && git push` | New commit(s) |
| 6 — Review | `git add . && git commit && git push` | New commit for fixes |
| 7 — Tests | `git add . && git commit && git push` | New commit (if any) |
| 8 — Video | `git add . && git commit && git push` | New commit with artifact |

## Acceptance Criteria

### Functional Requirements

- [ ] User can select the "Implement a Prompt" workflow from the type selection screen
- [ ] Phase 1 shows completed `prompt_chore_task` sessions for prompt selection
- [ ] Phase 1 allows manual prompt entry as alternative to session selection
- [ ] Phase 1 includes project selection with pre-selection from source session
- [ ] Phase 1 supports inline project creation (same as existing WizardPhase)
- [ ] Phase 2 skips title generation when a source session was selected
- [ ] Phase 2 generates title from prompt text when manual entry was used
- [ ] Phases 3-8 run non-interactively (no text input, no ask_user_question)
- [ ] Phases 3-4 share one AI session (planning)
- [ ] Phases 5-8 share a separate AI session (implementation)
- [ ] Phase 4 can auto-skip if AI determines deeper planning is unnecessary
- [ ] Phase 7 can auto-skip if AI determines no test-impacting changes exist
- [ ] Phase 8 auto-marks workflow as done on `phase_complete`
- [ ] All non-interactive phases show AI messages as they arrive
- [ ] Non-interactive phases show "Retry" on error and "Cancel" during execution
- [ ] Crafting board displays the new workflow type with correct badge and grouping
- [ ] Existing `prompt_chore_task` workflow continues to work unchanged

### Non-Functional Requirements

- [ ] No changes required to the crafting board for the new workflow (dynamic handling)
- [ ] Backward compatibility with existing `prompt_chore_task` sessions in the database
- [ ] Non-interactive phases have 15-minute timeout on AI queries
- [ ] AI session GenServer timeout (5 min) handles stale message flushing

### Quality Gates

- [ ] Feature file with Gherkin scenarios for the new workflow
- [ ] Tests for PromptWizardPhase (session listing, manual input, project selection, validation)
- [ ] Tests for non-interactive AiConversationPhase mode (render, retry, cancel)
- [ ] Tests for session strategy with `:new` creating second AI session
- [ ] All existing tests pass (`mix test`)
- [ ] `mix precommit` passes

## Dependencies & Prerequisites

- `ClaudeCode` library must support the `allowed_tools` option (already supported)
- Skills referenced in system prompts (`workflows:plan`, `workflows:work`, etc.) are external CLI skills — the AI invokes them via its tools, not as Elixir code

## Risk Analysis & Mitigation

| Risk | Impact | Likelihood | Mitigation |
|------|--------|-----------|------------|
| AI session timeout between non-interactive phases | Stalled workflow | Low | Flush stale timeout messages; near-instant transitions via `handle_skip_phase` |
| Non-interactive phase error with no recovery | Dead workflow | Medium | "Retry" button + "Cancel" button in non-interactive mode |
| AI calls `ask_user_question` in non-interactive phase | Hung phase | Medium | Exclude from allowed_tools + explicit prompt instruction |
| Context loss at planning→implementation boundary | Phase 5 has no plan | Medium | Deterministic `plan.md` path convention; fail-fast if missing |
| `derive_message_type` incorrectly classifying messages | Wrong UI rendering | High | Opt-driven via `message_type: :generated_prompt` in phase opts |
| SetupPhase sending duplicate `phase_complete` | Phase skip | High | Boolean guard + phase number guard in parent |
| Indefinite AI execution | Resource exhaustion | Medium | 15-minute GenServer.call timeout + max_turns |
| Stale phase_complete from PubSub timing | Phase skip | Medium | Guard `phase == socket.assigns.current_phase` in parent |

## File Change Summary

### New Files

| File | Purpose |
|------|---------|
| `lib/destila/workflows/implement_general_prompt_workflow.ex` | Workflow module with phases, callbacks, system prompts |
| `lib/destila_web/live/phases/prompt_wizard_phase.ex` | Phase 1 — prompt + project selection LiveComponent |
| `lib/destila_web/components/project_components.ex` | Shared project selection function component |
| `features/implement_general_prompt_workflow.feature` | Gherkin scenarios |
| `test/destila_web/live/implement_general_prompt_workflow_live_test.exs` | LiveView tests |

### Modified Files

| File | Change |
|------|--------|
| `lib/destila/workflows.ex` | Add to `@workflow_modules`, add `list_done_sessions_by_type/1` |
| `lib/destila/workflows/session.ex` | Add `:implement_general_prompt` to enum |
| `lib/destila/ai.ex` | Fix `derive_message_type` (opt-driven), update `get_ai_session_for_workflow` (latest), add `workflow_type_label` |
| `lib/destila/ai/claude_session.ex` | Add timeout to `query/3`, flush stale messages in `reset_timer`, try/catch in `stop_for_workflow_session` |
| `lib/destila/workers/ai_query_worker.ex` | Reorder enqueue-before-broadcast in `handle_skip_phase`, add unique constraints, handle `:new` with create_ai_session, auto-done on final phase |
| `lib/destila_web/live/phases/ai_conversation_phase.ex` | Remove dead PubSub code, add non-interactive mode (hide input, retry, cancel) |
| `lib/destila_web/live/phases/setup_phase.ex` | Fix duplicate send, conditional title gen |
| `lib/destila_web/live/phases/wizard_phase.ex` | Extract project selection into shared component |
| `lib/destila_web/live/workflow_runner_live.ex` | Add phase guard on `handle_info`, handle new workflow's session_create data |
| `lib/destila_web/components/board_components.ex` | Add badge/label for new workflow type |
| `lib/destila/workflows/prompt_chore_task_workflow.ex` | Add `message_type: :generated_prompt` to Phase 6 opts |

## References & Research

### Internal References

- Existing workflow: `lib/destila/workflows/prompt_chore_task_workflow.ex`
- Phase architecture plan: `docs/plans/2026-03-25-refactor-workflow-phase-architecture-plan.md`
- Session MCP tool refactor: `docs/plans/2026-03-27-refactor-replace-markers-with-session-mcp-tool-plan.md`
- WorkflowRunnerLive: `lib/destila_web/live/workflow_runner_live.ex`
- AiConversationPhase: `lib/destila_web/live/phases/ai_conversation_phase.ex`
- AiQueryWorker: `lib/destila/workers/ai_query_worker.ex`
- ClaudeSession: `lib/destila/ai/claude_session.ex`

### External References

- [Phoenix LiveView LiveComponent docs](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveComponent.html)
- [Oban recursive jobs guide](https://hexdocs.pm/oban/recursive-jobs.html)
- [Multi-step forms in Phoenix LiveView (Bernheisel)](https://bernheisel.com/blog/liveview-multi-step-form)
- [Elixir Registry docs](https://hexdocs.pm/elixir/Registry.html)
