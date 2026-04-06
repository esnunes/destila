---
title: "refactor: Convert PhaseExecution.status from string to Ecto.Enum"
type: refactor
date: 2026-04-06
---

# refactor: Convert PhaseExecution.status from string to Ecto.Enum

## Overview

`Destila.Executions.PhaseExecution` stores `status` as a plain `:string` with a `@statuses` module attribute and `validate_inclusion` for validation. Meanwhile, `Destila.Workflows.Session` already uses `Ecto.Enum` for its `phase_status` field. This inconsistency means no compile-time safety on phase execution status values — a typo like `"procesing"` would silently pass the changeset.

Converting to `Ecto.Enum` gives us:
- Compile-time validation of status atoms
- Consistent pattern with `Session.phase_status`
- Automatic validation (no manual `validate_inclusion` needed)

Since SQLite stores `Ecto.Enum` values as their string representation, no data migration is needed — existing `"pending"` rows are read back as `:pending` automatically.

## Changes

### Step 1: Update the PhaseExecution schema

**File:** `lib/destila/executions/phase_execution.ex`

1. Change `field(:status, :string, default: "pending")` → `field(:status, Ecto.Enum, values: [:pending, :processing, :awaiting_input, :awaiting_confirmation, :completed, :skipped, :failed], default: :pending)`
2. Remove the `@statuses` module attribute (`~w(pending awaiting_input processing awaiting_confirmation completed skipped failed)`)
3. Remove `validate_inclusion(:status, @statuses)` from `changeset/2` (Ecto.Enum handles validation)
4. Remove the `def statuses` function (no longer needed — `Ecto.Enum.values/2` can be used if ever needed)

### Step 2: Create a no-op migration

Run `mix ecto.gen.migration convert_phase_execution_status_to_enum`.

The migration body should be empty (no column changes needed) since SQLite stores `Ecto.Enum` as strings, which matches the existing column type. Add a comment explaining why.

### Step 3: Update status references in `Destila.Executions`

**File:** `lib/destila/executions.ex`

All string status literals become atoms:

| Location | Old | New |
|---|---|---|
| `create_phase_execution/3` (line 63) | `status: "pending"` | `status: :pending` |
| `complete_phase/2` (line 78) | `"completed"` | `:completed` |
| `stage_completion/2` (line 85) | `"awaiting_confirmation"` | `:awaiting_confirmation` |
| `reject_completion/1` (line 93) | `"awaiting_input"` | `:awaiting_input` |
| `skip_phase/2` (line 97) | `"skipped"` | `:skipped` |
| `start_phase/2` (line 103) | `"processing"` (default arg) | `:processing` |

### Step 4: Update status references in `Destila.Executions.Engine`

**File:** `lib/destila/executions/engine.ex`

| Location | Old | New |
|---|---|---|
| `start_session/1` (line 62) | `Executions.start_phase(pe, "processing")` | `Executions.start_phase(pe, :processing)` |
| `phase_update/3` (line 119) | `pe.status in ["awaiting_input", "awaiting_confirmation"]` | `pe.status in [:awaiting_input, :awaiting_confirmation]` |
| `phase_update/3` (line 120) | `Executions.update_phase_execution_status(pe, "processing")` | `Executions.update_phase_execution_status(pe, :processing)` |
| `handle_awaiting_input/1` (line 165) | `pe.status == "processing"` | `pe.status == :processing` |
| `handle_awaiting_input/1` (line 166) | `Executions.update_phase_execution_status(pe, "awaiting_input")` | `Executions.update_phase_execution_status(pe, :awaiting_input)` |
| `transition_to_phase/2` (line 192) | `Executions.start_phase(pe, "processing")` | `Executions.start_phase(pe, :processing)` |
| `handle_retry/1` (line 212) | `Executions.update_phase_execution_status(pe, "processing")` | `Executions.update_phase_execution_status(pe, :processing)` |
| `complete_current_phase_execution/1` (line 221) | `pe.status in ["completed", "skipped"]` | `pe.status in [:completed, :skipped]` |

### Step 5: Update status references in `WorkflowRunnerLive`

**File:** `lib/destila_web/live/workflow_runner_live.ex`

| Location | Old | New |
|---|---|---|
| `handle_event("decline_advance", ...)` (line 141) | `%{status: "awaiting_confirmation"}` | `%{status: :awaiting_confirmation}` |

### Step 6: Update test files

**File:** `test/destila/executions_test.exs`

All status string assertions and inputs become atoms:

| Line | Old | New |
|---|---|---|
| 26 | `assert pe.status == "pending"` | `assert pe.status == :pending` |
| 35 | `%{status: "processing"}` | `%{status: :processing}` |
| 37 | `assert pe.status == "processing"` | `assert pe.status == :processing` |
| 71 | `assert pe.status == "completed"` | `assert pe.status == :completed` |
| 81 | `assert pe.status == "skipped"` | `assert pe.status == :skipped` |
| 91 | `assert pe.status == "awaiting_confirmation"` | `assert pe.status == :awaiting_confirmation` |
| 95 | `assert pe.status == "completed"` | `assert pe.status == :completed` |
| 106 | `assert pe.status == "awaiting_input"` | `assert pe.status == :awaiting_input` |
| 115 | `assert pe.status == "processing"` | `assert pe.status == :processing` |

**File:** `test/destila/executions/engine_test.exs`

| Line | Old | New |
|---|---|---|
| 69 | `assert updated_pe.status == "awaiting_confirmation"` | `assert updated_pe.status == :awaiting_confirmation` |
| 76 | `%{status: "processing"}` | `%{status: :processing}` |
| 86 | `assert updated_pe.status == "awaiting_input"` | `assert updated_pe.status == :awaiting_input` |
| 140 | `assert updated_pe.status == "completed"` | `assert updated_pe.status == :completed` |
| 161 | `%{status: "awaiting_input"}` | `%{status: :awaiting_input}` |
| 169 | `assert updated_pe.status == "processing"` | `assert updated_pe.status == :processing` |
| 242 | `%{status: "awaiting_confirmation"}` | `%{status: :awaiting_confirmation}` |
| 247 | `assert completed_pe.status == "completed"` | `assert completed_pe.status == :completed` |

**File:** `test/destila_web/live/implement_general_prompt_workflow_live_test.exs`

| Line | Old | New |
|---|---|---|
| 259 | `%{status: "awaiting_input"}` | `%{status: :awaiting_input}` |
| 282 | `assert pe.status == "processing"` | `assert pe.status == :processing` |
| 290 | `%{status: "awaiting_input"}` | `%{status: :awaiting_input}` |
| 315 | `%{status: "awaiting_input"}` | `%{status: :awaiting_input}` |

### Step 7: Verify no remaining string references

Search for any remaining string status references related to phase execution:

```
grep -r '"pending"\|"processing"\|"awaiting_input"\|"awaiting_confirmation"\|"completed"\|"skipped"\|"failed"' lib/ test/
```

**Known false positives (do NOT change):**
- `lib/destila/workflows/setup.ex` — `"completed"` refers to setup step metadata status, not phase execution status
- `lib/destila_web/components/setup_components.ex` — `"completed"` / `"failed"` refer to setup step status rendering
- `lib/destila/workers/prepare_workflow_session.ex` — `"completed"` / `"failed"` refer to setup metadata values
- `lib/destila/workers/title_generation_worker.ex` — `"completed"` refers to title generation metadata status
- `test/destila/workflows_metadata_test.exs` — `"completed"` refers to metadata values
- `test/destila_web/live/brainstorm_idea_workflow_live_test.exs` — `"completed"` / `"failed"` refer to metadata values

These are all metadata status strings stored in JSON maps (not `PhaseExecution.status`).

### Step 8: Verify with `mix precommit`

Run `mix precommit` to confirm compilation, tests, and any other checks pass.

## Files modified

| File | Type of change |
|---|---|
| `lib/destila/executions/phase_execution.ex` | Schema: string → Ecto.Enum, remove @statuses, validate_inclusion, statuses/0 |
| `lib/destila/executions.ex` | String status args → atoms |
| `lib/destila/executions/engine.ex` | String status comparisons/args → atoms |
| `lib/destila_web/live/workflow_runner_live.ex` | String pattern match → atom |
| `priv/repo/migrations/*_convert_phase_execution_status_to_enum.exs` | No-op migration |
| `test/destila/executions_test.exs` | String assertions/inputs → atoms |
| `test/destila/executions/engine_test.exs` | String assertions/inputs → atoms |
| `test/destila_web/live/implement_general_prompt_workflow_live_test.exs` | String inputs/assertions → atoms |

## Files NOT modified (confirmed no phase execution status references)

- `lib/destila/ai/conversation.ex` — returns status atoms (`:processing`, `:awaiting_input`, etc.), no `PhaseExecution.status` references
- `lib/destila/workflows/setup.ex` — uses `"completed"` for metadata, not phase execution status
- `lib/destila_web/components/setup_components.ex` — uses `"completed"` / `"failed"` for setup step metadata
- `lib/destila/workers/prepare_workflow_session.ex` — uses `"completed"` / `"failed"` for setup metadata
- `lib/destila/workers/title_generation_worker.ex` — uses `"completed"` for title generation metadata

## Risk assessment

**Low risk.** Ecto.Enum stores atoms as their string representation in SQLite, so existing data is compatible without any column changes. The main risk is a missed string reference, which would cause a runtime pattern-match failure — mitigated by the comprehensive grep sweep in Step 7.
