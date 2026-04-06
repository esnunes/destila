---
title: "feat: Explicit phase execution state machine"
type: feat
date: 2026-04-06
---

# feat: Explicit phase execution state machine

## Overview

Phase execution state transitions are currently implicit — scattered across `Destila.Executions` (convenience functions like `complete_phase/2`, `stage_completion/2`) and `Destila.Executions.Engine` (orchestration logic that calls those functions). There is no single place that defines which transitions are valid, and nothing prevents an invalid one (e.g., `completed -> processing`).

This plan introduces a `Destila.Executions.StateMachine` module that:
- Defines the full transition map as data
- Provides a validated `transition!/3` that raises on invalid transitions
- Becomes the single gateway for all phase execution status writes

The `Executions` context functions become thin wrappers that delegate to `StateMachine.transition!/3`, preserving the existing public API and minimizing call-site changes in Engine and WorkflowRunnerLive.

## Prerequisite

F1 (Ecto.Enum conversion) must be merged first. Status is already `Ecto.Enum` atoms as of commit `78d24a6`.

## State transition map

```
pending              → [processing]
processing           → [awaiting_input, awaiting_confirmation, completed, skipped, failed]
awaiting_input       → [processing]
awaiting_confirmation → [completed, awaiting_input]
failed               → [processing]
completed            → []           (terminal)
skipped              → []           (terminal)
```

## Changes

### Step 1: Create `Destila.Executions.StateMachine`

**New file:** `lib/destila/executions/state_machine.ex`

```elixir
defmodule Destila.Executions.StateMachine do
  @moduledoc """
  Defines valid phase execution state transitions and provides
  a validated transition function.
  """

  alias Destila.Repo
  alias Destila.Executions.PhaseExecution

  @transitions %{
    pending:               [:processing],
    processing:            [:awaiting_input, :awaiting_confirmation, :completed, :skipped, :failed],
    awaiting_input:        [:processing],
    awaiting_confirmation: [:completed, :awaiting_input],
    failed:                [:processing],
    completed:             [],
    skipped:               []
  }

  @doc "Returns true if transitioning from `from` to `to` is allowed."
  def valid_transition?(from, to), do: to in Map.get(@transitions, from, [])

  @doc "Returns the list of states reachable from the given state."
  def allowed_transitions(state), do: Map.get(@transitions, state, [])

  @doc """
  Transitions a phase execution to a new status, persisting the change.

  Raises `ArgumentError` if the transition is invalid.
  Returns the updated `%PhaseExecution{}`.
  """
  def transition!(%PhaseExecution{status: from} = pe, to, attrs \\ %{}) do
    unless valid_transition?(from, to) do
      raise ArgumentError,
        "invalid phase execution transition: #{from} -> #{to} (pe: #{pe.id}, ws: #{pe.workflow_session_id})"
    end

    pe
    |> PhaseExecution.changeset(Map.put(attrs, :status, to))
    |> Repo.update!()
  end
end
```

Key design decisions:
- `transition!/3` uses `Repo.update!` (bang) — callers already assume success; failures are exceptional
- The error message includes the phase execution ID and workflow session ID for debugging
- `attrs` defaults to `%{}` so callers can pass additional field updates (e.g., `started_at`, `completed_at`, `staged_result`)

### Step 2: Rewire `Destila.Executions` context functions

**File:** `lib/destila/executions.ex`

Convert the existing convenience functions to delegate to `StateMachine.transition!/3`. This keeps the public API intact so Engine callers don't need to change.

| Function | Current implementation | New implementation |
|---|---|---|
| `update_phase_execution_status/3` (line 71) | Direct changeset + `Repo.update` | `{:ok, StateMachine.transition!(pe, status, attrs)}` |
| `complete_phase/2` (line 77) | Calls `update_phase_execution_status` | `{:ok, StateMachine.transition!(pe, :completed, %{result: result, completed_at: now()})}` |
| `stage_completion/2` (line 84) | Calls `update_phase_execution_status` | `{:ok, StateMachine.transition!(pe, :awaiting_confirmation, %{staged_result: result})}` |
| `confirm_completion/1` (line 88) | Calls `complete_phase` with staged result | `{:ok, StateMachine.transition!(pe, :completed, %{result: pe.staged_result, completed_at: now()})}` |
| `reject_completion/1` (line 92) | Calls `update_phase_execution_status` | `{:ok, StateMachine.transition!(pe, :awaiting_input, %{staged_result: nil})}` |
| `skip_phase/2` (line 96) | Calls `update_phase_execution_status` | `{:ok, StateMachine.transition!(pe, :skipped, %{result: ..., completed_at: now()})}` |
| `start_phase/2` (line 103) | Calls `update_phase_execution_status` | `{:ok, StateMachine.transition!(pe, status, %{started_at: now()})}` |

All functions continue to return `{:ok, pe}` tuples for backward compatibility. The bang is caught at the context boundary — if a transition is invalid, callers get an `ArgumentError` crash (loud, fast failure vs. a silent `{:error, changeset}` that nobody checks).

**Important:** The generic `update_phase_execution_status/3` must also validate via `StateMachine.transition!/3`. This ensures there's no backdoor.

### Step 3: Update `WorkflowRunnerLive.decline_advance`

**File:** `lib/destila_web/live/workflow_runner_live.ex`, line 137-147

The `decline_advance` handler currently calls `Destila.Executions.reject_completion(pe)` directly. This already works since `reject_completion` will delegate to `StateMachine.transition!/3` after Step 2. **No change needed** — the existing call through `Executions.reject_completion/1` is correct.

### Step 4: Create tests for `StateMachine`

**New file:** `test/destila/executions/state_machine_test.exs`

Test cases:

1. **`valid_transition?/2`** — verify each edge in the transition map returns `true`, and a selection of invalid edges return `false`:
   - `pending -> processing` = true
   - `pending -> completed` = false
   - `processing -> awaiting_input` = true
   - `completed -> processing` = false (terminal)
   - `skipped -> processing` = false (terminal)
   - `awaiting_confirmation -> completed` = true
   - `awaiting_confirmation -> awaiting_input` = true

2. **`allowed_transitions/1`** — spot-check a couple of states:
   - `processing` returns `[:awaiting_input, :awaiting_confirmation, :completed, :skipped, :failed]`
   - `completed` returns `[]`

3. **`transition!/3` happy paths**:
   - `pending -> processing` with `started_at` attrs — updates DB, returns updated struct
   - `processing -> completed` with `completed_at` and `result` — sets all fields
   - `awaiting_confirmation -> awaiting_input` with `staged_result: nil` — clears staged result

4. **`transition!/3` invalid transition**:
   - `completed -> processing` raises `ArgumentError` with message containing "invalid phase execution transition"
   - `pending -> awaiting_input` raises `ArgumentError`

5. **`transition!/3` with attrs**:
   - Verify additional attributes (like `staged_result`, `result`) are persisted alongside the status change

### Step 5: Update existing tests

**File:** `test/destila/executions_test.exs`

The existing tests call `Executions.complete_phase/2`, `Executions.stage_completion/2`, etc. These should continue to work since we're preserving the wrapper API. However, verify:

- Tests that create phase executions with `status: :processing` directly (via `create_phase_execution/3`) bypass the state machine — this is fine for test setup
- The "stage_completion and confirm_completion" test (line 86) does `pending -> awaiting_confirmation -> completed`. The `pending -> awaiting_confirmation` transition is **not** in our transition map. We need to either:
  - (a) Start the PE in `:processing` status before staging, or
  - (b) Add `:awaiting_confirmation` to `pending`'s allowed transitions

  Option (a) is correct — in real usage, a phase is always started (`:processing`) before it can be staged. Update the test to call `start_phase` first.

- Similarly, the "stage_completion and reject_completion" test (line 99) starts from `:pending`. Update it too.

- The "complete_phase sets status and completed_at" test (line 66) transitions `pending -> completed`. In the real flow, this goes through `processing` first. Update to start the PE first.

- The "skip_phase sets status, reason, and completed_at" test (line 76) transitions `pending -> skipped`. In real flow, skip happens from `processing`. Update to start the PE first.

**File:** `test/destila/executions/engine_test.exs`

Engine tests should pass as-is since they exercise the real flow (start -> process -> complete). Verify by running them.

### Step 6: Run `mix precommit`

Ensure all tests pass, no compiler warnings, and formatting is clean.

## File change summary

| File | Action |
|---|---|
| `lib/destila/executions/state_machine.ex` | **Create** — transition map + `transition!/3` |
| `lib/destila/executions.ex` | **Edit** — rewire all status-writing functions to delegate to `StateMachine` |
| `test/destila/executions/state_machine_test.exs` | **Create** — unit tests for state machine |
| `test/destila/executions_test.exs` | **Edit** — fix test setup to go through valid transitions |

## Risks and mitigations

1. **Tests that set status directly via `create_phase_execution/3`**: The `create_phase_execution` function writes initial status without going through the state machine (it's creation, not transition). This is intentional — creation always starts at `:pending`. The only risk is tests that start at non-`:pending` status for setup convenience. Engine tests do this (e.g., `create_phase_execution(ws, 1, %{status: :processing})`) and that's fine — creation isn't a transition.

2. **Engine's nil-guarded updates**: Several Engine call sites pattern-match `case Executions.get_current_phase_execution(ws.id)` with `nil -> :ok`. These nil guards remain necessary — the state machine only applies when we have a PE to transition.

3. **`confirm_completion` transition path**: `confirm_completion` goes `awaiting_confirmation -> completed`, which is valid. The `pe.staged_result` is read from the struct passed in — make sure the PE is freshly loaded (it is in current code since `confirm_completion` is called right after `stage_completion`).

## Done criteria

- A `StateMachine` module exists at `lib/destila/executions/state_machine.ex` with the transition map
- All phase execution status writes in `Executions` delegate to `StateMachine.transition!/3`
- An invalid transition raises `ArgumentError` with a descriptive message
- All existing tests pass (with necessary setup adjustments)
- New `StateMachine` unit tests cover valid/invalid transitions
- `mix precommit` passes
