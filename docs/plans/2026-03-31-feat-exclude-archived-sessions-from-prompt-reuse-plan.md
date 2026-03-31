# Plan: Exclude Archived Sessions from "Implement a Prompt" Session List

## Problem

In the "Implement a Prompt" workflow, Phase 1 (Prompt Wizard) displays a list of completed sessions with generated prompts for reuse. This list currently includes archived sessions, which should be excluded.

## Root Cause

The query `list_sessions_with_generated_prompts/0` in `lib/destila/workflows.ex:142-154` filters sessions by `not is_nil(ws.done_at)` (completed sessions with prompt metadata), but does **not** filter out archived sessions (`archived_at` is not checked).

Other listing queries in the same module (e.g., `list_workflow_sessions/0` at line 67) correctly filter with `where: is_nil(ws.archived_at)`.

## Implementation

### Step 1: Add `archived_at` filter to the query

**File:** `lib/destila/workflows.ex`
**Lines:** 142-154

Add `is_nil(ws.archived_at)` to the `where` clause of `list_sessions_with_generated_prompts/0`:

```elixir
def list_sessions_with_generated_prompts do
  from(ws in Session,
    join: m in SessionMetadata,
    on: m.workflow_session_id == ws.id and m.key == "prompt_generated",
    where: not is_nil(ws.done_at) and is_nil(ws.archived_at),
    preload: [:project],
    order_by: [desc: ws.done_at],
    select: {ws, m.value}
  )
  |> Repo.all()
  |> Enum.map(fn {ws, value} -> {ws, value["text"]} end)
  |> Enum.reject(fn {_ws, text} -> is_nil(text) || text == "" end)
end
```

The only change is on line 146: `where: not is_nil(ws.done_at)` becomes `where: not is_nil(ws.done_at) and is_nil(ws.archived_at)`.

### Step 2: Update the `@doc` comment

Update the docstring above the function (around line 138-141) to mention that archived sessions are excluded.

## Files Changed

| File | Change |
|------|--------|
| `lib/destila/workflows.ex` | Add `is_nil(ws.archived_at)` to `list_sessions_with_generated_prompts/0` where clause |

## Testing

1. Create a workflow session of type `:implement_general_prompt`, complete it through to `done_at` being set, with `prompt_generated` metadata
2. Verify it appears in the Prompt Wizard session list
3. Archive the session
4. Verify it no longer appears in the list
5. Unarchive it and verify it reappears
