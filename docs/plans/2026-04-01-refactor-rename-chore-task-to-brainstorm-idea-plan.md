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

Inside the file:
- Module name: `DestilaWeb.ChoreTaskWorkflowLiveTest` → `DestilaWeb.BrainstormIdeaWorkflowLiveTest`
- `@feature "chore_task_workflow"` → `@feature "brainstorm_idea_workflow"`
- All `:prompt_chore_task` atoms → `:brainstorm_idea`
- Route: `~p"/workflows/prompt_chore_task"` → `~p"/workflows/brainstorm_idea"`

### Step 9: Update all other test files

Every file below needs `:prompt_chore_task` → `:brainstorm_idea` and any string references updated:

| File | What to change |
|------|----------------|
| `test/destila_web/live/workflow_type_selection_live_test.exs` | `:prompt_chore_task` atom, `#type-prompt_chore_task` selector → `#type-brainstorm_idea` |
| `test/destila_web/live/crafting_board_live_test.exs` | `:prompt_chore_task` atom, `#workflow-board-prompt_chore_task` → `#workflow-board-brainstorm_idea`, any "Chore/Task" strings → "Brainstorm Idea" |
| `test/destila_web/live/archived_sessions_live_test.exs` | `:prompt_chore_task` → `:brainstorm_idea` |
| `test/destila_web/live/generated_prompt_viewing_live_test.exs` | `:prompt_chore_task` → `:brainstorm_idea` |
| `test/destila_web/live/implement_general_prompt_workflow_live_test.exs` | `:prompt_chore_task` → `:brainstorm_idea`, "Prompt for a Chore / Task" → "Brainstorm Idea" |
| `test/destila_web/live/project_inline_creation_live_test.exs` | `:prompt_chore_task` → `:brainstorm_idea` |
| `test/destila_web/live/session_archiving_live_test.exs` | `:prompt_chore_task` → `:brainstorm_idea` |
| `test/destila_web/live/projects_live_test.exs` | `:prompt_chore_task` → `:brainstorm_idea` |
| `test/destila/ai_test.exs` | `:prompt_chore_task` → `:brainstorm_idea` |
| `test/destila/workflow_test.exs` | `:prompt_chore_task` → `:brainstorm_idea` |
| `test/destila/workflows_classify_test.exs` | `:prompt_chore_task` → `:brainstorm_idea` |
| `test/destila/workflows_metadata_test.exs` | `:prompt_chore_task` → `:brainstorm_idea` |
| `test/destila/executions_test.exs` | `:prompt_chore_task` → `:brainstorm_idea` |
| `test/destila/executions/engine_test.exs` | `:prompt_chore_task` → `:brainstorm_idea` |

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

**File:** `.serena/memories/workflow-architecture-learnings.md`
- All `prompt_chore_task` → `brainstorm_idea`
- All `PromptChoreTaskWorkflow` → `BrainstormIdeaWorkflow`
- `"New Chore/Task"` → `"New Idea"`
- `chore task workflow` → `brainstorm idea workflow`
- `chore_task` references (where referring to the workflow type) → `brainstorm_idea`

**File:** `.serena/memories/project_overview.md`
- `chore task workflows with phases` → `brainstorm idea workflows with phases`
- `Chore task phases` → `Brainstorm Idea phases`

## Verification

After all changes:

1. `mix compile --warnings-as-errors` — ensure no compilation errors or dangling references
2. `mix ecto.migrate` — run the data migration
3. `mix test` — full test suite must pass
4. `mix precommit` — run the precommit alias
5. Grep for any remaining `prompt_chore_task`, `PromptChoreTask`, `Chore/Task`, or `chore_task` references outside `docs/brainstorms/` and `docs/plans/` to catch stragglers

## Risks

- **Partial rename causes runtime crashes.** Every pattern match on `:prompt_chore_task` must be found. Use grep to verify no references remain.
- **Ecto.Enum mismatch.** If the schema enum is updated before the migration runs, existing records with `:prompt_chore_task` will fail to load. Run migration first, or ensure tests use the new atom.
- **URL breakage.** The route `/workflows/:workflow_type` uses the atom as the URL segment. Old bookmarks to `/workflows/prompt_chore_task` will 404. This is acceptable for a rename.
