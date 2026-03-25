---
title: "feat: Split Waiting for Reply into Waiting for You and AI Processing sections"
type: feat
date: 2026-03-24
---

# Split "Waiting for Reply" into Two Sections

## Overview

Split the single "Waiting for Reply" section on the Crafting Board into two distinct sections — **"Waiting for You"** (user action needed) and **"AI Processing"** (AI is working) — so users can tell at a glance which sessions need their attention.

## Acceptance Criteria

- [x] `classify/1` in `lib/destila/workflow_sessions.ex` returns `:waiting_for_user` for `:conversing` and `:advance_suggested`, and `:ai_processing` for `:generating`
- [x] Crafting Board list view shows five sections in order: Setup, Waiting for You, AI Processing, In Progress, Done
- [x] Dashboard summary uses the same updated classification
- [x] Feature file updated with five-section scenario
- [x] Tests updated to verify the split
- [x] `mix precommit` passes

## MVP

### 1. Update `classify/1` — `lib/destila/workflow_sessions.ex:52-59`

Split the `:waiting` return into two:

```elixir
def classify(%WorkflowSession{} = workflow_session) do
  cond do
    workflow_session.column == :done -> :done
    workflow_session.phase_status == :setup -> :setup
    workflow_session.phase_status in [:conversing, :advance_suggested] -> :waiting_for_user
    workflow_session.phase_status == :generating -> :ai_processing
    true -> :in_progress
  end
end
```

### 2. Update Crafting Board — `lib/destila_web/live/crafting_board_live.ex`

Update module attributes:

```elixir
@sections [:setup, :waiting_for_user, :ai_processing, :in_progress, :done]

@section_labels %{
  setup: "Setup",
  waiting_for_user: "Waiting for You",
  ai_processing: "AI Processing",
  in_progress: "In Progress",
  done: "Done"
}

@section_icons %{
  setup: "hero-cog-6-tooth-micro",
  waiting_for_user: "hero-hand-raised-micro",
  ai_processing: "hero-cpu-chip-micro",
  in_progress: "hero-bolt-micro",
  done: "hero-check-circle-micro"
}

@section_empty_messages %{
  setup: "No sessions being set up",
  waiting_for_user: "No sessions waiting for you",
  ai_processing: "No sessions being processed by AI",
  in_progress: "No sessions in progress",
  done: "No completed sessions yet"
}
```

### 3. Update Dashboard — `lib/destila_web/live/dashboard_live.ex:36-49`

Update the section list and labels to match:

```elixir
defp crafting_summary(prompts) do
  grouped = Enum.group_by(prompts, &classify_crafting_prompt/1)

  Enum.map([:setup, :waiting_for_user, :ai_processing, :in_progress, :done], fn section ->
    {section, Map.get(grouped, section, [])}
  end)
end

defp section_label(:setup), do: "Setup"
defp section_label(:waiting_for_user), do: "Waiting for You"
defp section_label(:ai_processing), do: "AI Processing"
defp section_label(:in_progress), do: "In Progress"
defp section_label(:done), do: "Done"
```

### 4. Update Feature File — `features/crafting_board.feature`

Update description and "View sessions in sectioned list" scenario:

- Change feature description to reference five sections: Setup, Waiting for You, AI Processing, In Progress, Done
- Update scenario to assert five sections
- Add line for `phase_status "generating"` under "AI Processing"

### 5. Update Tests — `test/destila_web/live/crafting_board_live_test.exs`

- "shows four sections" test becomes "shows five sections" — assert `#section-waiting_for_user` and `#section-ai_processing` instead of `#section-waiting`
- "classifies prompts into correct sections" — `generating_prompt` moves to `#section-ai_processing`, `waiting_prompt` stays in `#section-waiting_for_user`
- "advance_suggested appears in waiting section" — update selector to `#section-waiting_for_user`
- Update `@tag scenario:` values to match renamed Gherkin scenario text

## Files Changed

| File | Action | Lines affected |
|------|--------|---------------|
| `lib/destila/workflow_sessions.ex` | Modify | Lines 52-59 (classify/1) |
| `lib/destila_web/live/crafting_board_live.ex` | Modify | Lines 8-14, 165-177 (module attrs) |
| `lib/destila_web/live/dashboard_live.ex` | Modify | Lines 36-49 (summary + labels) |
| `features/crafting_board.feature` | Modify | Lines 1-19 (description + scenario) |
| `test/destila_web/live/crafting_board_live_test.exs` | Modify | Lines 48-122 (section tests) |

## Constraints

- Section order: "Waiting for You" before "AI Processing" (actionable items first)
- No changes to card-level indicators (status dots, progress bars, badges)
- No changes to workflow board view or any other views
