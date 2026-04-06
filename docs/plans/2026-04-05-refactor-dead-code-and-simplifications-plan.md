---
title: "refactor: Remove dead code, eliminate redundant DB calls, and simplify flows"
type: refactor
date: 2026-04-05
---

# refactor: Remove dead code, eliminate redundant DB calls, and simplify flows

## Overview

After several rounds of refactoring (extracting `AI.Conversation`, inlining the conversation into the workflow runner, converting `SetupPhase` to a function component, extracting `CreateSessionLive`), there is accumulated dead code, redundant database queries, unused functions, and vestigial patterns that can be cleaned up.

This plan catalogs every finding and groups them into independent, reviewable changes.

## Findings

### 1. Dead code in `Destila.AI`

**1a. `AI.get_ai_session!/1` — never called outside its own module**

Defined at `lib/destila/ai.ex:13`. Not referenced anywhere in the codebase except the definition itself. No test or production caller uses it.

**Action:** Delete `get_ai_session!/1`.

**1b. `AI.list_messages/1` (by `ai_session_id`) — never called**

Defined at `lib/destila/ai.ex:53`. The codebase only uses `list_messages_for_workflow_session/1` (which queries across AI sessions by workflow_session_id). The `list_messages/1` function that takes a single `ai_session_id` has zero callers outside its definition.

**Action:** Delete `list_messages/1`.

### 2. Dead code in `Destila.Executions`

**2a. `Executions.get_phase_execution!/1` — only used in tests**

Defined at `lib/destila/executions.ex:16`. Referenced in `test/destila/executions/engine_test.exs` but never in production code. Every production caller uses `get_current_phase_execution/1` or `get_phase_execution_by_number/2` instead.

**Action:** Keep (used in tests). No change needed.

**2b. `Executions.list_phase_executions/1` — only used in tests**

Defined at `lib/destila/executions.ex:40`. Only referenced in `test/destila/executions_test.exs`.

**Action:** Keep (used in tests). No change needed.

**2c. `Executions.confirm_completion/1` — only used in tests**

Defined at `lib/destila/executions.ex:88`. Only referenced in `test/destila/executions_test.exs`. The production path for confirming phase advance goes through `Engine.advance_to_next/1`, not `confirm_completion/1`.

**Action:** Keep (used in tests for now). Flag as potentially dead after `phase_executions` migration is finalized.

### 3. Dead code in `Destila.AI.ClaudeSession`

**3a. `ClaudeSession.query/3` — unused in production**

Defined at `lib/destila/ai/claude_session.ex:103`. Only called from `test/destila/ai/session_test.exs`. All production code uses `query_streaming/3` via `AiQueryWorker`. The non-streaming `query/3` and its `handle_call({:query, ...})` handler + `collect_with_mcp/1` helper are dead production code.

**Action:** Delete `query/3`, the `handle_call({:query, ...})` clause, and the non-streaming `collect_with_mcp/1` helper. Update the test to use `query_streaming/3` instead (or keep `query/3` as test-only if streaming is harder to test). The `collect_with_mcp/1` helper shares the same accumulator logic as `collect_with_mcp_and_broadcast/2` — after removing the non-streaming path, there's no duplication to worry about.

**3b. `ClaudeSession.session_id/1` — never called**

Defined at `lib/destila/ai/claude_session.ex:121`. Zero callers in the entire codebase (including tests). The `session_id` is obtained from the streaming result via `result[:session_id]` in `Conversation.phase_update/2`.

**Action:** Delete `session_id/1` and its `handle_call(:session_id, ...)` clause.

### 4. Dead code in `DestilaWeb.ChatComponents`

**4a. `file_upload_input/1` — vestigial mock component**

Defined at `lib/destila_web/components/chat_components.ex:776`. This renders a "mocked" file upload UI and references a `mock_upload` event that no LiveView handles. It's referenced from `chat_input/1` via `:if={@input_type == :file_upload}` but no phase or AI response ever produces an `:file_upload` input type.

**Action:** Delete `file_upload_input/1` and remove the `:file_upload` branch from `chat_input/1`.

### 5. Dead handle_info patterns in `WorkflowRunnerLive`

**5a. `handle_info({:phase_complete, ...})` — orphaned message handler**

At `lib/destila_web/live/workflow_runner_live.ex:313-332`. These handle `{:phase_complete, phase, data}` messages, but nothing in the codebase sends this message. The old architecture had LiveComponents sending this; after inlining the conversation logic, phase completion goes through `Engine.advance_to_next/1` which updates the workflow session directly and broadcasts `:workflow_session_updated` via PubSub.

**Action:** Delete both `handle_info({:phase_complete, ...})` clauses.

**5b. `handle_info({:phase_event, ...})` — orphaned message handler**

At `lib/destila_web/live/workflow_runner_live.ex:335-337`. A catch-all no-op handler for `{:phase_event, event, data}` messages. Nothing sends this message.

**Action:** Delete this handler.

### 6. Dead event handling in `DashboardLive` and `CraftingBoardLive`

**6a. `:workflow_session_deleted` event — never broadcast**

Both `DashboardLive` and `CraftingBoardLive` handle `:workflow_session_deleted` in their PubSub listeners, but no code in the system broadcasts this event. `delete_project/1` broadcasts `:project_deleted`, and sessions are archived (not deleted).

**Action:** Remove `:workflow_session_deleted` from the `when event in [...]` guards in both LiveViews.

### 7. Unused assigns in `SetupComponents`

**7a. `@all_done` and `@has_failure` — assigned but never used in template**

At `lib/destila_web/components/setup_components.ex:21-22`, `all_done` and `has_failure` are computed and assigned but never referenced in the HEEx template. The old LiveComponent may have used them for conditional rendering.

**Action:** Delete `all_completed?/1`, `has_failure?/1`, and their `assign` calls.

### 8. Redundant DB calls — `ensure_ai_session` vs `get_or_create_ai_session`

**8a. Double-query in `Conversation.ensure_ai_session/1`**

`ensure_ai_session/1` calls `AI.get_ai_session_for_workflow/1`, and if nil, calls `AI.get_or_create_ai_session/1` — which internally calls `AI.get_ai_session_for_workflow/1` again. This results in 2 DB queries when a session exists (one in `ensure_ai_session`, one in `get_or_create_ai_session`) and 3 queries when nil (get → get_or_create.get → insert).

**Action:** Simplify `ensure_ai_session/1` to call `get_or_create_ai_session/1` directly (which already handles the get-or-create logic in one flow). Or inline the create path directly to avoid the redundant get.

### 9. Redundant DB call — `AiQueryWorker.perform/1`

**9a. Redundant `AI.get_ai_session_for_workflow` call in worker**

At `lib/destila/workers/ai_query_worker.ex:22`, the worker fetches the AI session record to validate it exists, then discards the result. The `ClaudeSession.session_opts_for_workflow/3` at line 28 fetches it *again* internally to get `claude_session_id` and `worktree_path`.

**Action:** Remove the redundant `AI.get_ai_session_for_workflow` call from the worker, or pass the ai_session to `session_opts_for_workflow` to avoid the second fetch.

### 10. Redundant DB calls — `Engine.phase_update/3` re-fetches workflow session

**10a. `Engine.phase_update/3` always re-fetches `ws` from DB**

Both clauses of `phase_update/3` start with `ws = Workflows.get_workflow_session!(workflow_session_id)`. The callers (AiQueryWorker and WorkflowRunnerLive) already have the session or its ID from a recent fetch. The LiveView calls `phase_update(ws.id, ws.current_phase, ...)` even though it has `ws` in assigns.

This is a deliberate pattern for freshness (the DB may have changed between the LiveView assign and the Engine call), so the trade-off is correctness vs. performance. However, in `WorkflowRunnerLive.handle_event("send_text", ...)`, the session is re-fetched again *after* `phase_update` returns (line 198). This means 3 DB queries per user message: LiveView's assigns → Engine re-fetch → LiveView re-fetch.

**Action:** Accept the Engine's re-fetch as necessary for correctness. But optimize the LiveView by not re-fetching after `phase_update` when `update_workflow_session` at the end of `Engine.phase_update` already broadcasted an update via PubSub, which the `handle_info(:workflow_session_updated, ...)` handler picks up.

However, the current code needs the re-fetch for immediate rendering before the PubSub message arrives. Leave as-is unless profiling shows this is a bottleneck. Low priority.

### 11. Simplify `handle_auto_advance` — duplicates `advance_to_next`

**11a. `Engine.handle_auto_advance/2` is nearly identical to `advance_to_next/1`**

`handle_auto_advance/2` (line 148) does the same thing as `advance_to_next/1` (line 33): complete current phase execution → check if next phase exceeds total → complete_workflow or transition_to_phase. The only difference is that `advance_to_next` reads `next_phase` from `ws.current_phase + 1` while `handle_auto_advance` takes `current_phase` as a parameter (which is the phase that was active when the AI result arrived).

Since `Engine.phase_update/3` passes `ws.current_phase` as the phase to `handle_auto_advance`, and `advance_to_next/1` reads `ws.current_phase + 1`, the semantics differ: `handle_auto_advance(ws, phase)` advances from `phase` (the phase the AI was working on), while `advance_to_next(ws)` advances from `ws.current_phase` (which was already updated). But in practice, for `phase_update`, `phase` equals `ws.current_phase`, making them equivalent.

**Action:** Replace `handle_auto_advance/2` with a call to `advance_to_next(ws)`. This eliminates the duplication. The phase parameter in `phase_update` is only needed to override `ws.current_phase` for `Conversation.phase_update`, which already uses `%{ws | current_phase: phase}`.

### 12. Simplify `Workflows.classify/1` — dual-state fallback

**12a. `classify/1` checks both `phase_executions` and `phase_status`**

`Workflows.classify/1` first checks `Executions.get_current_phase_execution`, then falls back to `workflow_session.phase_status`. The docstring mentions "migration period" backwards compatibility. Since `phase_executions` are now fully integrated (every phase transition creates/updates them via the Engine), the legacy `phase_status` fallback could potentially be removed.

However, `phase_status` is still actively written by the Engine in every transition, and several UI components read `phase_status` directly. The `classify/1` function's fallback adds a DB query (to `phase_executions`) on every call — including from `CraftingBoardLive` which calls it for every session on every PubSub update.

**Action:** Simplify `classify/1` to only use `phase_status` (which is already on the loaded session — no extra DB query needed). The `phase_executions` table is useful for execution history but redundant for current classification since `phase_status` is always kept in sync.

### 13. Simplify `step_label/2` in `SetupComponents`

**13a. Dead catch-all clause**

`step_label/2` at line 105-106 has a catch-all `step_label(_, _)` that returns `""`. Only `"title_gen"` ever matches the first clause. The function is only called with `"title_gen"` because the repo_sync and worktree steps have their labels hardcoded in the `build_steps/2` function.

**Action:** Inline the title_gen label into `build_steps/2` and remove `step_label/2` entirely.

### 14. Simplify `get_metadata` — called from workflow prompts

**14a. `Workflows.get_metadata/1` re-queries `get_all_metadata/1` then reduces**

`get_metadata/1` calls `get_all_metadata/1` (which returns all metadata records from DB) then reduces to a flat map. `get_all_metadata/1` is also called directly by `assign_metadata/2` in `WorkflowRunnerLive` which does its own reduce.

The workflow prompt functions (e.g., `task_description_prompt/1`, `plan_prompt/1`) call `get_metadata/1` each time a phase starts. `Conversation.handle_session_strategy/1` also calls it. Multiple prompts in the same phase start result in multiple DB queries for the same data.

**Action:** This is a minor optimization. Consider passing metadata as a parameter to `phase_start` instead of having each prompt function fetch it independently. But given the low frequency (once per phase start), this is low priority.

### 15. Dead `Setup.update/2` ignores params

**15a. The `_params` argument in `Setup.update/2` is unused**

At `lib/destila/workflows/setup.ex:36`, the `_params` argument is ignored. The function only reads metadata from DB. The params (containing `setup_step_completed: key`) are not used because the function checks all setup keys' statuses rather than just the one that completed.

**Action:** This works correctly but is slightly misleading. The function re-queries all metadata to check completeness, which is safe. No change needed — the approach is correct (checking all steps is more robust than trusting the individual step notification).

### 16. Unused `Phase.final` field

**16a. `Phase.final` — set but never checked in Engine**

`Phase.final` is set to `true` on the last phase of both workflows (`Prompt Generation` in brainstorm, `Adjustments` in implementation). However, no code in `Engine`, `Conversation`, or `WorkflowRunnerLive` ever reads `phase.final`. Phase completion is determined by `next_phase > ws.total_phases`, not by checking `final`.

**Action:** Remove `final: false` from `Phase` struct default and remove `final: true` from both workflow definitions. If desired behavior changes in the future (e.g., final phases should auto-mark-done), re-add it then.

### 17. Unused `Phase.skippable` field

**17a. `Phase.skippable` — set but never checked in Engine**

`Phase.skippable` is set to `true` on phases like "Gherkin Review", "Deepen Plan", "Browser Tests", "Feature Video". However, no code checks this field. Phase skipping is handled by the AI calling `mcp__destila__session` with `action: "phase_complete"`, not by checking the field.

**Action:** Remove `skippable: false` from `Phase` struct default and remove `skippable: true` from both workflow definitions. The AI's system prompt instructs it when to skip; the field is metadata that nothing consumes.

## Implementation plan

Each item is an independent, self-contained change that can be reviewed and merged separately. Items are ordered from safest (pure deletions) to riskier (behavioral simplifications).

### Step 1: Remove dead functions

Delete the following unused functions:

- `AI.get_ai_session!/1`
- `AI.list_messages/1`
- `ClaudeSession.session_id/1` + `handle_call(:session_id, ...)`
- `ChatComponents.file_upload_input/1` + `:file_upload` branch in `chat_input/1`

Files: `lib/destila/ai.ex`, `lib/destila/ai/claude_session.ex`, `lib/destila_web/components/chat_components.ex`

### Step 2: Remove dead message handlers

Delete orphaned `handle_info` clauses:

- `WorkflowRunnerLive.handle_info({:phase_complete, ...})` (both clauses)
- `WorkflowRunnerLive.handle_info({:phase_event, ...})`
- `:workflow_session_deleted` from event guards in `DashboardLive` and `CraftingBoardLive`

Files: `lib/destila_web/live/workflow_runner_live.ex`, `lib/destila_web/live/dashboard_live.ex`, `lib/destila_web/live/crafting_board_live.ex`

### Step 3: Remove unused assigns and helpers in `SetupComponents`

- Delete `all_completed?/1`, `has_failure?/1`, and their assigns
- Inline `step_label/2` into `build_steps/2` and delete the function

File: `lib/destila_web/components/setup_components.ex`

### Step 4: Remove unused `Phase` struct fields

- Remove `final` and `skippable` from `Phase` struct
- Remove `final: true` and `skippable: true` from both workflow definitions

Files: `lib/destila/workflows/phase.ex`, `lib/destila/workflows/brainstorm_idea_workflow.ex`, `lib/destila/workflows/implement_general_prompt_workflow.ex`

### Step 5: Remove unused `ClaudeSession.query/3` (non-streaming path)

- Delete `query/3`, `handle_call({:query, ...})`, and the non-streaming `collect_with_mcp/1`
- Update `test/destila/ai/session_test.exs` to use `query_streaming/3` if it uses `query/3`

Files: `lib/destila/ai/claude_session.ex`, `test/destila/ai/session_test.exs`

### Step 6: Eliminate redundant DB query in `ensure_ai_session`

Simplify `Conversation.ensure_ai_session/1`:

```elixir
# Before (2-3 queries):
defp ensure_ai_session(ws) do
  case AI.get_ai_session_for_workflow(ws.id) do  # query 1
    nil ->
      metadata = Workflows.get_metadata(ws.id)
      worktree_path = get_in(metadata, ["worktree", "worktree_path"])
      {:ok, session} = AI.get_or_create_ai_session(ws.id, %{...})  # query 2 (redundant get)
      session
    session -> session
  end
end

# After (1-2 queries):
defp ensure_ai_session(ws) do
  case AI.get_or_create_ai_session(ws.id, fn ->
    metadata = Workflows.get_metadata(ws.id)
    %{worktree_path: get_in(metadata, ["worktree", "worktree_path"])}
  end) do
    {:ok, session} -> session
  end
end
```

Or simpler — just replace with `AI.get_or_create_ai_session/2` directly since the metadata lookup only matters on creation:

```elixir
defp ensure_ai_session(ws) do
  metadata = Workflows.get_metadata(ws.id)
  worktree_path = get_in(metadata, ["worktree", "worktree_path"])
  {:ok, session} = AI.get_or_create_ai_session(ws.id, %{worktree_path: worktree_path})
  session
end
```

File: `lib/destila/ai/conversation.ex`

### Step 7: Eliminate redundant DB query in `AiQueryWorker`

Remove the standalone `AI.get_ai_session_for_workflow` guard-check. Let `session_opts_for_workflow` handle it (it already fetches the ai_session). If no ai_session exists, the session opts will simply not include `:resume`, which is correct behavior.

File: `lib/destila/workers/ai_query_worker.ex`

### Step 8: Replace `handle_auto_advance` with `advance_to_next`

In `Engine.phase_update/3`, replace `handle_auto_advance(ws, phase)` with `advance_to_next(ws)` and delete `handle_auto_advance/2`.

File: `lib/destila/executions/engine.ex`

### Step 9: Simplify `Workflows.classify/1` — remove `phase_executions` query

Remove the `Executions.get_current_phase_execution` call and use only `phase_status`:

```elixir
def classify(%Session{} = ws) do
  cond do
    Session.done?(ws) -> :done
    ws.phase_status in [:awaiting_input, :advance_suggested] -> :waiting_for_user
    true -> :processing
  end
end
```

This eliminates a DB query per session on every classify call (impactful for CraftingBoardLive which classifies all sessions).

Files: `lib/destila/workflows.ex`

### Step 10: Run `mix precommit` and fix any issues

Verify all tests pass and no compiler warnings remain.

## Non-changes (considered but rejected)

- **`Executions.get_phase_execution!/1`**, **`list_phase_executions/1`**, **`confirm_completion/1`**: Used in tests. Keeping them avoids churn in test files.
- **`get_or_create_ai_session/2`**: Still needed by `ensure_ai_session` after simplification.
- **`Setup.update/2` ignoring params**: The approach (re-check all steps) is more robust than checking individual step completion.
- **Multiple `get_workflow_session!` calls in Engine**: Each re-fetch ensures fresh state after potentially concurrent modifications. Necessary for correctness.
- **`get_metadata` called per prompt function**: Low frequency (once per phase start). Not worth the added complexity of passing metadata as a parameter.
