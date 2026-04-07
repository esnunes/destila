---
title: "feat: Messages FK directly to workflow_sessions"
type: feat
date: 2026-04-06
---

# feat: Messages FK directly to workflow_sessions

## Overview

Add a `workflow_session_id` column directly to the `messages` table so message queries don't need to join through `ai_sessions`. Currently, `list_messages_for_workflow_session/1` must join `messages → ai_sessions → workflow_sessions`. When `session_strategy: :new` creates a fresh AI session per phase, messages split across multiple `ai_session` records, making the join even more important. A direct FK eliminates the join and simplifies the query path.

The existing `ai_session_id` column remains for provenance (which specific Claude session produced the message).

## Prerequisites

None — this is independent of the phase execution refactoring chain.

## Changes

### Step 1: Create migration

**File:** `priv/repo/migrations/TIMESTAMP_add_workflow_session_id_to_messages.exs`

```elixir
defmodule Destila.Repo.Migrations.AddWorkflowSessionIdToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :workflow_session_id, references(:workflow_sessions, type: :binary_id, on_delete: :delete_all)
    end

    # Backfill from ai_sessions
    execute(
      "UPDATE messages SET workflow_session_id = (SELECT workflow_session_id FROM ai_sessions WHERE ai_sessions.id = messages.ai_session_id)",
      "UPDATE messages SET workflow_session_id = NULL"
    )

    # Make NOT NULL after backfill
    alter table(:messages) do
      modify :workflow_session_id, :binary_id, null: false
    end

    create index(:messages, [:workflow_session_id])
  end
end
```

**Key decisions:**
- `on_delete: :delete_all` — matches the existing cascade chain (workflow_sessions → ai_sessions → messages). When a workflow session is deleted, its messages should go too.
- Backfill uses a correlated subquery — each message gets `workflow_session_id` from its parent `ai_session`.
- Column made NOT NULL after backfill to ensure data integrity going forward.
- Separate `execute/2` for backfill so it's reversible (down migration NULLs the column).

### Step 2: Update Message schema

**File:** `lib/destila/ai/message.ex`

Add `belongs_to(:workflow_session, ...)` and include `:workflow_session_id` in the changeset cast list:

```elixir
schema "messages" do
  field(:role, Ecto.Enum, values: [:system, :user])
  field(:content, :string, default: "")
  field(:raw_response, :map)
  field(:selected, {:array, :string})
  field(:phase, :integer, default: 1)

  belongs_to(:ai_session, Destila.AI.Session)
  belongs_to(:workflow_session, Destila.Workflows.Session)

  field(:inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []})
end

def changeset(message, attrs) do
  message
  |> cast(attrs, [
    :ai_session_id,
    :workflow_session_id,
    :role,
    :content,
    :raw_response,
    :selected,
    :phase
  ])
  |> validate_required([:ai_session_id, :workflow_session_id, :role])
  |> validate_number(:phase, greater_than_or_equal_to: 1)
end
```

**Note:** `:workflow_session_id` is added to `validate_required` since the column is NOT NULL. Every message must have both `ai_session_id` (which Claude session) and `workflow_session_id` (which workflow).

### Step 3: Update `Workflows.Session` schema (optional has_many)

**File:** `lib/destila/workflows/session.ex`

Add a `has_many` for direct message access:

```elixir
has_many(:messages, Destila.AI.Message, foreign_key: :workflow_session_id)
```

This is optional but provides `Repo.preload(ws, :messages)` support if needed later.

### Step 4: Simplify `AI.list_messages_for_workflow_session/1`

**File:** `lib/destila/ai.ex`, lines 49–57

Replace the join-based query with a direct FK query:

```elixir
def list_messages_for_workflow_session(workflow_session_id) do
  Repo.all(
    from(m in Message,
      where: m.workflow_session_id == ^workflow_session_id,
      order_by: m.inserted_at
    )
  )
end
```

### Step 5: Update `AI.create_message/2` signature

**File:** `lib/destila/ai.ex`, lines 59–69

The function currently takes `(ai_session_id, attrs)` and merges `ai_session_id` into attrs. Update it to also accept `workflow_session_id` in attrs — no signature change needed since `workflow_session_id` flows through the attrs map. But we need to ensure callers pass it.

No code change needed in `create_message/2` itself — the changeset in Step 2 already handles `:workflow_session_id` via `cast`.

### Step 6: Pass `workflow_session_id` in `AI.Conversation`

**File:** `lib/destila/ai/conversation.ex`

All three `phase_update/2` clauses and the `mark_done` handler that create messages need to pass `workflow_session_id`. The `ws` struct is available in all call sites.

#### `:message` clause (line 34)

```elixir
def phase_update(ws, %{message: message}) do
  phase_number = ws.current_phase
  ai_session = AI.get_ai_session_for_workflow(ws.id)

  if ai_session do
    AI.create_message(ai_session.id, %{
      role: :user,
      content: message,
      phase: phase_number,
      workflow_session_id: ws.id
    })

    enqueue_ai_worker(ws, phase_number, message)
    :processing
  else
    :awaiting_input
  end
end
```

#### `:ai_result` clause (line 52)

```elixir
AI.create_message(ai_session.id, %{
  role: :system,
  content: content,
  raw_response: result,
  phase: phase_number,
  workflow_session_id: ws.id
})
```

#### `:ai_error` clause (line 91)

```elixir
AI.create_message(ai_session.id, %{
  role: :system,
  content: "Something went wrong. Please try sending your message again.",
  phase: phase_number,
  workflow_session_id: ws.id
})
```

### Step 7: Pass `workflow_session_id` in `WorkflowRunnerLive`

**File:** `lib/destila_web/live/workflow_runner_live.ex`

#### `mark_done` handler (line 153)

The `mark_done` event creates a completion message. Pass `workflow_session_id`:

```elixir
def handle_event("mark_done", _params, socket) do
  ws = socket.assigns.workflow_session
  ai_session = AI.get_ai_session_for_workflow(ws.id)

  if ai_session do
    AI.create_message(ai_session.id, %{
      role: :system,
      content: Workflows.completion_message(ws.workflow_type),
      phase: ws.current_phase,
      workflow_session_id: ws.id
    })
  end

  {:ok, ws} =
    Workflows.update_workflow_session(ws, %{done_at: DateTime.utc_now()})

  {:noreply,
   socket
   |> assign(:workflow_session, ws)
   |> assign_ai_state(ws)}
end
```

### Step 8: Update tests

All test files that call `AI.create_message/2` need to pass `workflow_session_id`. These are:

| File | Lines | Context |
|------|-------|---------|
| `test/destila/executions/engine_test.exs` | 52 | `create_session_with_ai` helper |
| `test/destila_web/live/brainstorm_idea_workflow_live_test.exs` | 90, 97, 114, 640, 698 | `create_session_in_phase` helper + individual tests |
| `test/destila_web/live/implement_general_prompt_workflow_live_test.exs` | 223, 244, 265, 293, 315 | Phase-specific test setups |
| `test/destila_web/live/session_archiving_live_test.exs` | 55, 85 | Archive/unarchive test setup |
| `test/destila_web/live/generated_prompt_viewing_live_test.exs` | 58 | Generated prompt test setup |

**Pattern:** In each `create_message` call, add `workflow_session_id: ws.id` (where `ws` is the workflow session variable in scope). The exact variable name varies per test — some use `ws`, some use `session`, some have it available through the test context.

**Example** — `engine_test.exs` helper:

Before:
```elixir
AI.create_message(ai_session.id, %{
  role: :user,
  content: "test message",
  phase: 1
})
```

After:
```elixir
AI.create_message(ai_session.id, %{
  role: :user,
  content: "test message",
  phase: 1,
  workflow_session_id: ws.id
})
```

### Step 9: Run `mix precommit`

Run `mix precommit` to verify:
- Compilation succeeds with no warnings
- Migration runs cleanly
- All tests pass
- Code is formatted

## Risk assessment

| Risk | Mitigation |
|------|-----------|
| Backfill fails if any message has no ai_session | The `ai_session_id` column is NOT NULL, so every message has an ai_session, and every ai_session has a `workflow_session_id`. The subquery will always return a value. |
| Existing code breaks if `workflow_session_id` not passed | `validate_required` in the changeset will catch missing `workflow_session_id` at the Ecto level. Tests will surface any missed call sites. |
| Migration not reversible | The `execute/2` with down migration (`SET NULL`) + `change` for column addition makes it fully reversible. |

## Done when

- Messages have a direct `workflow_session_id` FK column (NOT NULL, indexed)
- `list_messages_for_workflow_session/1` queries directly on `messages.workflow_session_id` (no join)
- All `create_message` call sites pass `workflow_session_id`
- The `ai_session_id` column remains for provenance
- `mix precommit` passes
