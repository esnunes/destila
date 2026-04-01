# Rename "Prompt for a Chore / Task" → "Brainstorm Idea"

**Date:** 2026-04-01
**Type:** Refactor
**Scope:** Full rename across all layers — UI labels, code identifiers, database, tests, features, memory files

## Context

The "Prompt for a Chore / Task" workflow is being renamed to "Brainstorm Idea" to better reflect its purpose. This is strictly a rename — no behavioral changes.

## What stays the same

- All 6 phases, their order, system prompts, and logic
- The `hero-wrench-screwdriver` icon and `text-warning` / `badge-warning` classes
- Files under `docs/brainstorms/` and `docs/plans/` (historical artifacts)
- The workflow description: `"Straightforward coding tasks, bug fixes, or refactors"`
- The completion message text

## Implementation steps

### Step 1: Database migration

Create migration `priv/repo/migrations/YYYYMMDDHHMMSS_rename_prompt_chore_task_to_brainstorm_idea.exs`:

```elixir
defmodule Destila.Repo.Migrations.RenamePromptChoreTaskToBrainstormIdea do
  use Ecto.Migration

  def up do
    execute "UPDATE workflow_sessions SET workflow_type = 'brainstorm_idea' WHERE workflow_type = 'prompt_chore_task'"
  end

  def down do
    execute "UPDATE workflow_sessions SET workflow_type = 'prompt_chore_task' WHERE workflow_type = 'brainstorm_idea'"
  end
end
```

Run with `mix ecto.migrate`.

### Step 2: Rename workflow module file

| Old path | New path |
|----------|----------|
| `lib/destila/workflows/prompt_chore_task_workflow.ex` | `lib/destila/workflows/brainstorm_idea_workflow.ex` |

Inside the file:
- Module name: `Destila.Workflows.PromptChoreTaskWorkflow` → `Destila.Workflows.BrainstormIdeaWorkflow`
- `@moduledoc` — update "Chore/Task workflow" → "Brainstorm Idea workflow"
- `default_title/0` — `"New Chore/Task"` → `"New Idea"`
- `label/0` — `"Prompt for a Chore / Task"` → `"Brainstorm Idea"`

### Step 3: Update workflow registry

**File:** `lib/destila/workflows.ex` (line 13)

```elixir
# Old
prompt_chore_task: Destila.Workflows.PromptChoreTaskWorkflow,
# New
brainstorm_idea: Destila.Workflows.BrainstormIdeaWorkflow,
```

### Step 4: Update Ecto schema enum

**File:** `lib/destila/workflows/session.ex` (line 9)

```elixir
# Old
field(:workflow_type, Ecto.Enum, values: [:prompt_chore_task, :implement_general_prompt])
# New
field(:workflow_type, Ecto.Enum, values: [:brainstorm_idea, :implement_general_prompt])
```

### Step 5: Update board components

**File:** `lib/destila_web/components/board_components.ex`

| Line | Old | New |
|------|-----|-----|
| 139 | `def workflow_label(:prompt_chore_task), do: "Chore/Task"` | `def workflow_label(:brainstorm_idea), do: "Brainstorm Idea"` |
| 143 | `defp workflow_badge_class(:prompt_chore_task), do: "badge-warning"` | `defp workflow_badge_class(:brainstorm_idea), do: "badge-warning"` |

### Step 6: Update AI module

**File:** `lib/destila/ai.ex` (line 248)

```elixir
# Old
defp workflow_type_label(:prompt_chore_task), do: "chore/task"
# New
defp workflow_type_label(:brainstorm_idea), do: "brainstorm idea"
```

### Step 7: Update prompt wizard phase

**File:** `lib/destila_web/live/phases/prompt_wizard_phase.ex` (line 200)

```
# Old
Complete a Chore/Task workflow first, or write a prompt manually
# New
Complete a Brainstorm Idea workflow first, or write a prompt manually
```

### Step 8: Rename test file and update contents

| Old path | New path |
|----------|----------|
| `test/destila_web/live/chore_task_workflow_live_test.exs` | `test/destila_web/live/brainstorm_idea_workflow_live_test.exs` |

Inside the file — apply **all** of these (not just atom swaps):
- Module name: `DestilaWeb.ChoreTaskWorkflowLiveTest` → `DestilaWeb.BrainstormIdeaWorkflowLiveTest`
- Moduledoc: `"Chore/Task AI-Driven Workflow"` → `"Brainstorm Idea AI-Driven Workflow"` (line 3)
- Moduledoc: `"features/chore_task_workflow.feature"` → `"features/brainstorm_idea_workflow.feature"` (line 4)
- `@feature "chore_task_workflow"` → `@feature "brainstorm_idea_workflow"` (line 10)
- Comment: `# Creates a chore_task session` → `# Creates a brainstorm_idea session` (line 38)
- Fixture title: `"Test Chore Task"` → `"Test Brainstorm Idea"` (line 75)
- All `:prompt_chore_task` atoms → `:brainstorm_idea` (lines 76, 127, 154, 166, 184, 427, 565, 617)
- Routes: `~p"/workflows/prompt_chore_task"` → `~p"/workflows/brainstorm_idea"` (lines 127, 154, 166)
- Assertion: `render(view) =~ "Test Chore Task"` → `render(view) =~ "Test Brainstorm Idea"` (line 398)

### Step 9: Update all other test files

Each file below needs specific changes beyond simple atom swaps. The **catch-all rule** is: within every file, replace all occurrences of `:prompt_chore_task` with `:brainstorm_idea`, but also update these additional items per file:

**`test/destila/workflow_test.exs`** (11 occurrences):
- Alias: `alias Destila.Workflows.PromptChoreTaskWorkflow` → `alias Destila.Workflows.BrainstormIdeaWorkflow` (line 4)
- Describe block: `"Destila.Workflow behaviour via PromptChoreTaskWorkflow"` → `"Destila.Workflow behaviour via BrainstormIdeaWorkflow"` (line 7)
- All `PromptChoreTaskWorkflow.` calls → `BrainstormIdeaWorkflow.` (lines 9, 13–15, 19–20, 24, 31–32)

**`test/destila/ai_test.exs`** (12 occurrences):
- All `:prompt_chore_task` atoms → `:brainstorm_idea` (lines 14, 26, 37, 49, 61, 71, 86, 99, 112)
- Test name: `"returns title for a chore/task"` → `"returns title for a brainstorm idea"` (line 5)
- Test name: `"returns title for a chore task with different idea"` → `"returns title for a brainstorm idea with different idea"` (line 17)
- String assertion: `assert query =~ "chore/task"` → `assert query =~ "brainstorm idea"` (line 91)

**`test/destila_web/live/implement_general_prompt_workflow_live_test.exs`**:
- Helper function: `create_completed_chore_task_session` → `create_completed_brainstorm_idea_session` (definition on line 38, calls on lines 127, 136)
- Fixture title: `"Completed Chore Task"` → `"Completed Brainstorm Idea"` (line 43)
- All `:prompt_chore_task` atoms → `:brainstorm_idea` (line 44)
- Test name: `"shows completed chore/task sessions for selection"` → `"shows completed brainstorm idea sessions for selection"` (line 126)

**`test/destila_web/live/workflow_type_selection_live_test.exs`**:
- Atom reference: `_ = :prompt_chore_task` → `_ = :brainstorm_idea` (line 13)
- Selector: `"#type-prompt_chore_task"` → `"#type-brainstorm_idea"` (lines 28, 35)
- Path assertion: `assert path == "/workflows/prompt_chore_task"` → `assert path == "/workflows/brainstorm_idea"` (line 38)

**`test/destila_web/live/crafting_board_live_test.exs`**:
- All `:prompt_chore_task` atoms → `:brainstorm_idea` (lines 33, 82, 133, 238, 264, 271, 294, 300, 307, 340, 347)
- Selectors: `"#workflow-board-prompt_chore_task"` → `"#workflow-board-brainstorm_idea"` (lines 282, 300)
- Comment: `# Chore/Task board should have phase columns` → `# Brainstorm Idea board should have phase columns` (line 284)

**`test/destila_web/live/project_inline_creation_live_test.exs`**:
- Atom reference: `_ = :prompt_chore_task` → `_ = :brainstorm_idea` (line 13)
- Routes: `~p"/workflows/prompt_chore_task"` → `~p"/workflows/brainstorm_idea"` (lines 30, 52, 70, 89, 104)

**Simple atom-only files** (just replace `:prompt_chore_task` → `:brainstorm_idea`):
- `test/destila_web/live/archived_sessions_live_test.exs` (line 28)
- `test/destila_web/live/generated_prompt_viewing_live_test.exs` (line 48)
- `test/destila_web/live/session_archiving_live_test.exs` (line 28)
- `test/destila_web/live/projects_live_test.exs` (line 200)
- `test/destila/workflows_classify_test.exs` (line 9)
- `test/destila/workflows_metadata_test.exs` (line 10)
- `test/destila/executions_test.exs` (line 10)
- `test/destila/executions/engine_test.exs` (line 21)

### Step 10: Rename and update feature files

**Rename:** `features/chore_task_workflow.feature` → `features/brainstorm_idea_workflow.feature`

Inside the file:
- `Feature: Prompt for a Chore / Task Workflow` → `Feature: Brainstorm Idea Workflow`
- All `"Prompt for a Chore / Task"` strings → `"Brainstorm Idea"`

**Update:** `features/crafting_board.feature`
- `"Prompt for a Chore / Task"` → `"Brainstorm Idea"` (line 66)
- `"Chore/Task"` → `"Brainstorm Idea"` (line 68)

**Update:** `features/implement_general_prompt_workflow.feature`
- `"Prompt for a Chore / Task"` → `"Brainstorm Idea"` (line 34)

### Step 11: Update `.serena/memories/` files

**File:** `.serena/memories/workflow-architecture-learnings.md` (12 occurrences):
- Line 4: `"chore task workflow implementation"` → `"brainstorm idea workflow implementation"`
- Line 61: `":prompt_chore_task"` → `":brainstorm_idea"`
- Line 75: `"Phase 3 of chore_task"` → `"Phase 3 of brainstorm_idea"`
- Line 95: `"prompt_chore_task Phase 1"` → `"brainstorm_idea Phase 1"`
- Line 103: `"prompt_chore_task Phase 2"` → `"brainstorm_idea Phase 2"`
- Line 116: `"prompt_chore_task Phases 3-6"` → `"brainstorm_idea Phases 3-6"`
- Line 123: `PromptChoreTaskWorkflow` → `BrainstormIdeaWorkflow` (code example)
- Line 141: `"New Chore/Task"` → `"New Idea"` (code example)
- Line 223: `"prompt_chore_task, the session"` → `"brainstorm_idea, the session"`
- Line 283: `"features/chore_task_workflow.feature"` → `"features/brainstorm_idea_workflow.feature"`

**File:** `.serena/memories/project_overview.md` (2 occurrences):
- Line 8: `"chore task workflows with phases"` → `"brainstorm idea workflows with phases"`
- Line 30: `"Chore task phases"` → `"Brainstorm Idea phases"`

## Implementation order note

All code changes (Steps 2–11) should be made together in a single commit, with the migration (Step 1) included. The order in which you edit files does not matter — what matters is that everything is consistent by the time you compile and run tests.

- **Tests** use `MIX_ENV=test` which rebuilds the DB from `structure.sql` / migrations each run, so the migration and schema enum change are applied together.
- **Production** (dev database): run `mix ecto.migrate` after deploying. Since the migration converts existing data and the schema accepts the new enum, they are safe to deploy in one step. There is no window where old data conflicts with the new schema because Ecto.Enum stores values as strings in SQLite.

## Verification

After all changes:

1. `mix compile --warnings-as-errors` — ensure no compilation errors or dangling references
2. `mix ecto.migrate` — run the data migration
3. `mix test` — full test suite must pass
4. `mix precommit` — run the precommit alias
5. Run these greps to catch stragglers (exclude `docs/brainstorms/` and `docs/plans/`):
   ```bash
   grep -r "prompt_chore_task" lib/ test/ features/ .serena/
   grep -r "PromptChoreTask" lib/ test/ features/ .serena/
   grep -ri "chore.task" lib/ test/ features/ .serena/
   grep -ri "chore_task" lib/ test/ features/ .serena/
   ```
   All of these should return zero results.

## Risks

- **Partial rename causes runtime crashes.** Every pattern match on `:prompt_chore_task` must be found. Use grep to verify no references remain.
- **Ecto.Enum mismatch.** If the schema enum is updated before the migration runs, existing records with `:prompt_chore_task` will fail to load. Run migration first, or ensure tests use the new atom.
- **URL breakage.** The route `/workflows/:workflow_type` uses the atom as the URL segment. Old bookmarks to `/workflows/prompt_chore_task` will 404. This is acceptable for a rename.
