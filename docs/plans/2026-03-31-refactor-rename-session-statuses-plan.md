# Rename Session Statuses: Remove "In Progress" and Rename "AI Processing" to "Processing"

## Summary

The crafting board currently has two statuses that should be consolidated:
- **`:in_progress`** ("In Progress") — a catch-all that no longer makes sense
- **`:ai_processing`** ("AI Processing") — too specific, should just be "Processing" to accommodate non-AI work

Both should be merged into a single **`:processing`** status with the display label **"Processing"**.

> **Note:** The `"in_progress"` string used for **setup step statuses** (in `setup_worker.ex`, `title_generation_worker.ex`, and `setup_phase.ex`) is a different concept — those are individual step-level statuses, not session classification statuses. They are **out of scope** for this change.

## Changes

### 1. `lib/destila/workflows.ex` — classify/1 function

**Lines 113–139**: Update the classify function:
- Change `:ai_processing` → `:processing` on line 128 (when phase execution status is "processing")
- Change `:ai_processing` → `:processing` on line 134 (fallback when phase_status is :processing)
- Change `:in_progress` → `:processing` on line 135 (catch-all fallback)

```elixir
# Before
%{status: "processing"} ->
  :ai_processing
...
:processing -> :ai_processing
_ -> :in_progress

# After
%{status: "processing"} ->
  :processing
...
:processing -> :processing
_ -> :processing
```

### 2. `lib/destila_web/live/crafting_board_live.ex` — sections and labels

**Lines 9–16**: Update `@sections` and `@section_labels`:
- Remove `:ai_processing` and `:in_progress` from `@sections`
- Add `:processing` in their place (single entry)
- Update `@section_labels` accordingly

```elixir
# Before
@sections [:setup, :waiting_for_user, :ai_processing, :in_progress, :done]
@section_labels %{
  setup: "Setup",
  waiting_for_user: "Waiting for You",
  ai_processing: "AI Processing",
  in_progress: "In Progress",
  done: "Done"
}

# After
@sections [:setup, :waiting_for_user, :processing, :done]
@section_labels %{
  setup: "Setup",
  waiting_for_user: "Waiting for You",
  processing: "Processing",
  done: "Done"
}
```

**Lines 166–180**: Update `@section_icons` and `@section_empty_messages`:
- Remove `:ai_processing` and `:in_progress` entries
- Add `:processing` entry (keep the cpu-chip icon or bolt icon — cpu-chip is more appropriate)

```elixir
@section_icons %{
  setup: "hero-cog-6-tooth-micro",
  waiting_for_user: "hero-hand-raised-micro",
  processing: "hero-cpu-chip-micro",
  done: "hero-check-circle-micro"
}

@section_empty_messages %{
  setup: "No sessions being set up",
  waiting_for_user: "No sessions waiting for you",
  processing: "No sessions being processed",
  done: "No completed sessions yet"
}
```

### 3. `lib/destila_web/live/dashboard_live.ex` — section helpers

**Line 39**: Update the section list in `crafting_summary/1`:
```elixir
# Before
Enum.map([:setup, :waiting_for_user, :ai_processing, :in_progress, :done], fn section ->

# After
Enum.map([:setup, :waiting_for_user, :processing, :done], fn section ->
```

**Lines 46–50**: Update `section_label/1` function clauses:
- Remove `:ai_processing` and `:in_progress` clauses
- Add `:processing` clause

```elixir
# Before
defp section_label(:ai_processing), do: "AI Processing"
defp section_label(:in_progress), do: "In Progress"

# After
defp section_label(:processing), do: "Processing"
```

### 4. `test/destila/workflows_classify_test.exs` — update tests

**Lines 42–46**: Rename test and update assertion:
```elixir
# Before
test "returns :ai_processing when phase execution is processing" do
  ...
  assert Workflows.classify(ws) == :ai_processing

# After
test "returns :processing when phase execution is processing" do
  ...
  assert Workflows.classify(ws) == :processing
```

**Lines 53–56**: Update fallback test:
```elixir
# Before
test "falls back to phase_status :processing when no phase execution exists" do
  ...
  assert Workflows.classify(ws) == :ai_processing

# After
test "falls back to phase_status :processing when no phase execution exists" do
  ...
  assert Workflows.classify(ws) == :processing
```

**Lines 58–61**: Update catch-all test:
```elixir
# Before
test "falls back to :in_progress when no phase execution and nil phase_status" do
  ...
  assert Workflows.classify(ws) == :in_progress

# After
test "falls back to :processing when no phase execution and nil phase_status" do
  ...
  assert Workflows.classify(ws) == :processing
```

### 5. Test files referencing `:ai_processing` or `:in_progress` classification

Search and update any test assertions in:
- `test/destila_web/live/crafting_board_live_test.exs`
- `test/destila_web/live/implement_general_prompt_workflow_live_test.exs`
- `test/destila_web/live/chore_task_workflow_live_test.exs`

Update references to:
- `"AI Processing"` → `"Processing"` (UI label text)
- `"In Progress"` → `"Processing"` (UI label text)
- `:ai_processing` → `:processing` (atom references)
- `:in_progress` → `:processing` (atom references)

## Out of Scope

- **Setup step statuses** (`"in_progress"` in `setup_worker.ex`, `title_generation_worker.ex`, `setup_phase.ex`) — these are step-level statuses for setup progress indicators, not session classification statuses
- **Database schema changes** — no migration needed; the classify function is purely derived, not stored
- **Plan docs** in `docs/plans/` — historical references don't need updating
