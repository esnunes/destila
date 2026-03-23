---
title: "feat: Redesign Crafting Board with Sectioned List, Workflow Grouping, and Project Filter"
type: feat
date: 2026-03-23
---

# Redesign Crafting Board

## Overview

Replace the current 3-column kanban board on `/crafting` with a **sectioned list view** (default), a **"Group by Workflow" toggle** showing read-only per-workflow boards, and a **project filter**. Remove drag-and-drop from this page entirely — section/column assignment is derived from prompt state.

## Problem Statement

The current kanban board (Request → Distill → Done) provides a flat view of all crafting prompts with no way to filter by project or see prompts grouped by workflow phase. The column names (Request, Distill) don't convey meaningful status to the user. As the number of prompts grows, the board becomes hard to scan.

## Proposed Solution

### Default View: Sectioned List

Four computed sections based on prompt state:

| Section | Criteria | Notes |
|---------|----------|-------|
| **Setup** | `phase_status == :setup` | Only chore_task prompts during Phase 0 (git/worktree setup, title generation). Static workflows skip this state. |
| **Waiting for Reply** | `phase_status in [:generating, :conversing, :advance_suggested]` | Only chore_task prompts. `:generating` included because the user is waiting for the AI. |
| **In Progress** | Everything else with `column != :done` | All active prompts not in Setup or Waiting for Reply. |
| **Done** | `column == :done` | Prompt crafting is complete, ready for implementation board. |

**Why not `steps_completed == 0` for Setup?** Prompts are created with `steps_completed: 1` in `new_prompt_live.ex:166`. The value 0 never occurs in the current data model. The actual "setup" state is `phase_status == :setup`, set only for chore_task workflows during Phase 0.

**Why include `:generating` in Waiting for Reply?** From the user's perspective, the AI is processing their input — they are waiting for a reply. Placing it in "In Progress" would be misleading since the user cannot take action.

### Group by Workflow Toggle

When toggled, display a separate board per workflow type (hide empty ones). Each board has columns corresponding to the workflow's phase names, plus a "Done" column at the end.

**Phase name definitions:**

| Workflow | Phase 0 | Phase 1 | Phase 2 | Phase 3 | Phase 4 | Done |
|----------|---------|---------|---------|---------|---------|------|
| **Chore/Task** | Setup | Task Description | Gherkin Review | Technical Concerns | Prompt Generation | Done |
| **Feature Request** | — | Problem | Feature Type | Affected Areas | Mockups | Done |
| **Project** | — | Project Idea | Tech Stack | V1 Features | — | Done |

- Chore/Task Phase 0 ("Setup") is included as a column because it represents active git/worktree setup
- Feature Request and Project have no Phase 0 (static workflows skip setup)
- Prompts are placed in columns by `steps_completed` value
- Done prompts (`column == :done`) go in the "Done" column regardless of `steps_completed`

**Unified phase name interface:** Create `Destila.Workflows.phase_name/2` that accepts `(workflow_type, phase_number)` and returns the phase name. Delegates to `ChoreTaskPhases.phase_name/1` for `:chore_task`, implements directly for static workflows.

### Project Filter

- Dropdown lists all projects that have at least one prompt on the crafting board
- Includes an "All projects" option to clear the filter
- Clicking a project name on any card activates the filter for that project
- Prompts without a project appear when no filter is active, hidden when a filter is active
- Filter state persisted in URL query params via `handle_params/3`

### URL State

Persist both filter and toggle in query params:

```
/crafting                           → default list view, no filter
/crafting?project=<id>              → filtered by project
/crafting?view=workflow             → grouped by workflow
/crafting?view=workflow&project=<id> → grouped + filtered
```

Use `push_patch/2` for filter/toggle changes so the LiveView stays mounted.

## Technical Approach

### Phase 1: Data Layer Changes

**File: `lib/destila/prompts.ex`**

Modify `list_prompts/1` to always preload `:project`:

```elixir
# lib/destila/prompts.ex
def list_prompts(board) do
  from(p in Prompt, where: p.board == ^board, order_by: [asc: :position])
  |> preload(:project)
  |> Repo.all()
end
```

This benefits all call sites (CraftingBoardLive, ImplementationBoardLive, DashboardLive) since project context is useful everywhere.

**File: `lib/destila/workflows.ex`**

Add unified phase name interface:

```elixir
# lib/destila/workflows.ex

def phase_name(:chore_task, phase), do: ChoreTaskPhases.phase_name(phase)

def phase_name(:feature_request, 1), do: "Problem"
def phase_name(:feature_request, 2), do: "Feature Type"
def phase_name(:feature_request, 3), do: "Affected Areas"
def phase_name(:feature_request, 4), do: "Mockups"

def phase_name(:project, 1), do: "Project Idea"
def phase_name(:project, 2), do: "Tech Stack"
def phase_name(:project, 3), do: "V1 Features"

def phase_name(_type, _phase), do: nil

def phase_columns(workflow_type) do
  # Returns list of {phase_number, phase_name} tuples for board columns
  range = case workflow_type do
    :chore_task -> 0..total_steps(workflow_type)
    _ -> 1..total_steps(workflow_type)
  end

  columns =
    range
    |> Enum.map(fn n -> {n, phase_name(workflow_type, n)} end)
    |> Enum.reject(fn {_, name} -> is_nil(name) end)

  columns ++ [{:done, "Done"}]
end
```

### Phase 2: Rewrite CraftingBoardLive

**File: `lib/destila_web/live/crafting_board_live.ex`**

Complete rewrite. Key changes:

1. **Use `handle_params/3`** instead of only `mount/3` for URL-driven state
2. **Remove `card_moved` event handler** — no drag-and-drop
3. **Add `toggle_view`, `filter_project`, `clear_filter` events**
4. **Compute sections/boards from prompt list + current view mode**

```elixir
# Simplified structure

defmodule DestilaWeb.CraftingBoardLive do
  use DestilaWeb, :live_view

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
    end

    {:ok,
     socket
     |> assign(:current_user, session["current_user"])
     |> assign(:page_title, "Crafting Board")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    prompts = Destila.Prompts.list_prompts(:crafting)
    view_mode = if params["view"] == "workflow", do: :workflow, else: :list
    project_filter = params["project"]

    {:noreply,
     socket
     |> assign(:view_mode, view_mode)
     |> assign(:project_filter, project_filter)
     |> assign(:all_prompts, prompts)
     |> assign_derived_state()}
  end
end
```

**Section classification function** (pure function, easily testable):

```elixir
def classify_prompt(prompt) do
  cond do
    prompt.column == :done -> :done
    prompt.phase_status == :setup -> :setup
    prompt.phase_status in [:generating, :conversing, :advance_suggested] -> :waiting
    true -> :in_progress
  end
end
```

**Derived state computation:**

```elixir
defp assign_derived_state(socket) do
  prompts = socket.assigns.all_prompts
  project_filter = socket.assigns.project_filter

  # Filter by project if active
  filtered = if project_filter do
    Enum.filter(prompts, &(&1.project_id == project_filter))
  else
    prompts
  end

  # Collect unique projects for dropdown
  projects =
    prompts
    |> Enum.map(& &1.project)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.name)

  socket
  |> assign(:filtered_prompts, filtered)
  |> assign(:projects, projects)
  |> assign_view_data(filtered)
end
```

For the **list view**, group filtered prompts into `%{setup: [...], waiting: [...], in_progress: [...], done: [...]}`.

For the **workflow view**, group by `workflow_type` first, then by phase column within each type. Only include workflow types that have at least one prompt.

### Phase 3: Template and Components

**Template structure:**

```heex
<Layouts.app flash={@flash} current_user={@current_user} page_title={@page_title}>
  <!-- Header with title, project filter dropdown, view toggle, New Prompt button -->
  <div id="crafting-board-header">
    <h1>Crafting Board</h1>
    <.project_filter projects={@projects} selected={@project_filter} />
    <.view_toggle mode={@view_mode} />
    <.link navigate={~p"/prompts/new?from=/crafting"}>New Prompt</.link>
  </div>

  <!-- Conditional view rendering -->
  <%= if @view_mode == :list do %>
    <.sectioned_list sections={@sections} project_filter={@project_filter} />
  <% else %>
    <.workflow_boards boards={@workflow_boards} project_filter={@project_filter} />
  <% end %>
</Layouts.app>
```

**Card component** — adapted from existing `board_card/1` in `board_components.ex`:
- Shows: title (link to `/prompts/:id`), project name (clickable, triggers filter), phase number
- No `data-id` or Sortable hook attributes
- Preserves `title_generating` pulse animation

**Project filter** — a `<select>` element with `phx-change="filter_project"`:
- "All projects" option (empty value)
- List of projects with prompts on the crafting board

**View toggle** — a button/checkbox with `phx-click="toggle_view"`

**Sortable hook** — remains in codebase, still used by ImplementationBoardLive. No changes needed.

### Phase 4: Update Feature File and Tests

**File: `features/crafting_board.feature`** — new file with the Gherkin scenarios (updated from spec to match corrected classification logic).

**Test file: `test/destila_web/live/crafting_board_live_test.exs`** — new file.

Test cases:
1. **Section assignment** — create prompts with various states, verify they appear in correct sections
2. **Card content** — verify title, project name, phase number render
3. **Project filter via dropdown** — select project, verify only matching prompts shown
4. **Project filter via card click** — click project name, verify filter activates
5. **Clear filter** — clear selection, verify all prompts shown
6. **Toggle workflow view** — toggle on, verify boards with phase columns appear
7. **Empty workflow boards hidden** — verify boards with no prompts don't render
8. **Combined filter + grouping** — filter + toggle, verify both apply
9. **URL state** — verify query params update on filter/toggle changes
10. **PubSub refresh** — verify board updates when prompts change

## Acceptance Criteria

### Functional Requirements

- [x] Default view shows four sections: Setup, Waiting for Reply, In Progress, Done
- [x] Section assignment is computed from prompt state (`phase_status`, `column`)
- [x] Each card shows title (navigable), project name (clickable filter), phase number
- [x] Project filter dropdown lists projects with crafting prompts
- [x] Clicking project name on card activates filter
- [x] Filter can be cleared to show all prompts
- [x] "Group by Workflow" toggle shows per-workflow boards with phase columns + Done
- [x] Empty workflow boards are hidden
- [x] Filter persists across view toggle
- [x] Filter and toggle state persisted in URL query params
- [x] Real-time updates via PubSub continue to work
- [x] No drag-and-drop on this page
- [x] `list_prompts/1` preloads `:project` association
- [x] `Destila.Workflows.phase_name/2` provides phase names for all workflow types
- [x] `Destila.Workflows.phase_columns/1` returns column definitions per workflow type

### Quality Gates

- [x] All sections in `classify_prompt/1` have dedicated test cases
- [x] LiveView integration tests cover all Gherkin scenarios
- [x] `mix precommit` passes
- [x] Feature file `features/crafting_board.feature` created and linked to tests

## Sort Order

Within each section (list view) and each column (workflow view), prompts are sorted by `position` ascending (preserving existing order). This is the current behavior and requires no changes.

## Empty States

- **Sectioned list**: All four sections always visible. Empty sections show a subtle "No prompts" placeholder.
- **Workflow view**: Only boards with prompts are shown. If all boards are empty (e.g., filter yields zero results), show a single "No prompts match your filter" message.
- **Zero prompts total**: Show all four empty sections with a prominent "Create your first prompt" CTA.

## Implementation Phases

### Phase 1: Data Layer (low risk)
1. Add `:project` preload to `list_prompts/1` in `lib/destila/prompts.ex`
2. Add `phase_name/2` and `phase_columns/1` to `lib/destila/workflows.ex`
3. Verify no regressions in existing board views

### Phase 2: LiveView Rewrite (medium risk)
4. Rewrite `lib/destila_web/live/crafting_board_live.ex` with new mount/handle_params/render
5. Add `classify_prompt/1` helper (private function or in a shared module)
6. Implement filter and toggle event handlers with `push_patch`
7. Add new components for sectioned list, workflow boards, project filter, view toggle

### Phase 3: Feature File + Tests (low risk)
8. Create `features/crafting_board.feature`
9. Create `test/destila_web/live/crafting_board_live_test.exs`
10. Run `mix precommit` and fix any issues

## Files Changed

| File | Action | Description |
|------|--------|-------------|
| `lib/destila/prompts.ex` | Modify | Add `:project` preload to `list_prompts/1` |
| `lib/destila/workflows.ex` | Modify | Add `phase_name/2`, `phase_columns/1` |
| `lib/destila_web/live/crafting_board_live.ex` | Rewrite | New sectioned list + workflow grouping + project filter |
| `lib/destila_web/components/board_components.ex` | Modify | Add/adapt card component for new design (no Sortable attrs) |
| `features/crafting_board.feature` | Create | Gherkin scenarios for all crafting board behavior |
| `test/destila_web/live/crafting_board_live_test.exs` | Create | LiveView integration tests |

## References

### Internal References
- `lib/destila_web/live/crafting_board_live.ex` — current implementation (69 lines)
- `lib/destila_web/components/board_components.ex` — existing board components (123 lines)
- `lib/destila/prompts.ex` — prompts context (68 lines)
- `lib/destila/prompts/prompt.ex` — prompt schema (54 lines)
- `lib/destila/workflows/chore_task_phases.ex` — existing phase names (170 lines)
- `lib/destila/workflows.ex` — workflow step definitions (118 lines)
- `lib/destila_web/live/new_prompt_live.ex:155-169` — prompt creation (steps_completed starts at 1)
- `assets/js/hooks/sortable.js` — Sortable hook (stays, used by implementation board)

### Spec Flow Analysis Gaps Addressed
- **Setup section**: Corrected from `steps_completed == 0` (never occurs) to `phase_status == :setup`
- **`:generating` classification**: Placed in "Waiting for Reply" (user is waiting for AI)
- **Done column in workflow view**: Added explicit "Done" column per workflow board
- **URL state persistence**: Filter and toggle stored in query params
- **Sort order**: Preserved existing `position` ordering
- **Empty states**: Defined for all views
