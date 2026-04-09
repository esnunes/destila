---
title: "refactor: Promote user_prompt to first-class session column"
type: refactor
date: 2026-04-09
---

# refactor: Promote user_prompt to first-class session column

## Overview

The user's initial input (idea, prompt, or message) is currently stored as a row in `workflow_session_metadata` under the "creation" phase, with a different key per workflow type: "idea" (BrainstormIdea), "user_prompt" (CodeChat), "prompt" (ImplementGeneralPrompt). Workflow phases then read this value back via `get_in(metadata, [key, "text"])`.

This refactor promotes the initial prompt to a `user_prompt` text column on `workflow_sessions`, eliminating the per-workflow key indirection and the metadata round-trip.

## Current state

- **Session schema** (`lib/destila/workflows/session.ex:7-33`): No `user_prompt` field.
- **Session creation** (`lib/destila/workflows.ex:95-142`): Calls `creation_config(workflow_type)` to get `dest_key`, then `upsert_metadata(ws.id, "creation", dest_key, %{"text" => input_text})`.
- **`creation_config` callback** (`lib/destila/workflows/workflow.ex:41-52`): Returns `{source_metadata_key, label, dest_metadata_key}`.
  - `BrainstormIdeaWorkflow:29` — `{nil, "Idea", "idea"}`
  - `CodeChatWorkflow:37` — `{nil, "Prompt", "user_prompt"}`
  - `ImplementGeneralPromptWorkflow:104` — `{"prompt_generated", "Prompt", "prompt"}`
- **System prompt readers**:
  - `brainstorm_idea_workflow.ex:84-86` — `get_in(metadata, ["idea", "text"])`
  - `code_chat_workflow.ex:50-52` — `get_in(metadata, ["user_prompt", "text"])`
  - `implement_general_prompt_workflow.ex:122-124` — `get_in(metadata, ["prompt", "text"])`
- **Dispatcher functions** (`lib/destila/workflows.ex:43-58`): `creation_config/1`, `list_source_sessions/1`, `creation_label/1` all destructure the `creation_config` tuple.

## Key design decisions

### 1. Replace `creation_config/0` with two separate callbacks

`creation_config/0` returns a 3-tuple: `{source_metadata_key, label, dest_metadata_key}`. After this refactor, `dest_metadata_key` is gone. Rather than keeping a 2-tuple, split into two focused callbacks:

- `creation_label/0` — returns the input field label string ("Idea", "Prompt")
- `source_metadata_key/0` — returns the exported metadata key to find source sessions, or `nil`

This is cleaner than a tuple and each callback has a single responsibility. The dispatcher functions in `workflows.ex` (`creation_label/1`, `list_source_sessions/1`) call these directly.

### 2. Backfill migration maps workflow_type to the correct metadata key

The migration joins `workflow_sessions` to `workflow_session_metadata` on `workflow_session_id` where `phase_name = 'creation'` and `key` matches the workflow-type-specific key. A single `UPDATE ... FROM` with a `CASE` expression handles all three mappings:

- `brainstorm_idea` → key `"idea"`
- `code_chat` → key `"user_prompt"`
- `implement_general_prompt` → key `"prompt"`

After backfilling, the migration deletes those specific creation-phase metadata rows.

### 3. No nil check on `session.user_prompt` in system prompts

The current code conditionally includes the user prompt context only when the metadata value is non-nil and non-empty. After the refactor, `session.user_prompt` is always set during creation — it's written directly on the session record. The conditional check (`if user_prompt && user_prompt != ""`) can remain for safety since we still have the backfill scenario and it's a trivial check, not defensive code.

## Implementation steps

### Step 1: Migration — add column, backfill, delete old metadata

Create `priv/repo/migrations/<timestamp>_add_user_prompt_to_workflow_sessions.exs`:

**Important: this project uses SQLite (`ecto_sqlite3`), so all raw SQL must use SQLite-compatible syntax** — `json_extract()` instead of `->>`, `lower(hex(randomblob(16)))` instead of `gen_random_uuid()`, `json_object()` instead of `jsonb_build_object()`, and `datetime('now')` instead of `NOW()`.

```elixir
defmodule Destila.Repo.Migrations.AddUserPromptToWorkflowSessions do
  use Ecto.Migration

  def up do
    alter table(:workflow_sessions) do
      add :user_prompt, :text
    end

    flush()

    # Backfill from creation-phase metadata, mapping workflow_type to the correct key
    execute """
    UPDATE workflow_sessions
    SET user_prompt = json_extract(m.value, '$.text')
    FROM workflow_session_metadata m
    WHERE m.workflow_session_id = workflow_sessions.id
      AND m.phase_name = 'creation'
      AND (
        (workflow_sessions.workflow_type = 'brainstorm_idea' AND m.key = 'idea')
        OR (workflow_sessions.workflow_type = 'code_chat' AND m.key = 'user_prompt')
        OR (workflow_sessions.workflow_type = 'implement_general_prompt' AND m.key = 'prompt')
      )
    """

    # Delete the old creation-phase metadata rows
    execute """
    DELETE FROM workflow_session_metadata
    WHERE phase_name = 'creation'
      AND key IN ('idea', 'user_prompt', 'prompt')
    """
  end

  def down do
    # Re-create metadata rows from the column
    execute """
    INSERT INTO workflow_session_metadata (id, workflow_session_id, phase_name, key, value, exported, inserted_at, updated_at)
    SELECT
      lower(hex(randomblob(16))),
      ws.id,
      'creation',
      CASE ws.workflow_type
        WHEN 'brainstorm_idea' THEN 'idea'
        WHEN 'code_chat' THEN 'user_prompt'
        WHEN 'implement_general_prompt' THEN 'prompt'
      END,
      json_object('text', ws.user_prompt),
      0,
      datetime('now'),
      datetime('now')
    FROM workflow_sessions ws
    WHERE ws.user_prompt IS NOT NULL
    """

    alter table(:workflow_sessions) do
      remove :user_prompt
    end
  end
end
```

### Step 2: Update Session schema

**`lib/destila/workflows/session.ex`**

Add `field(:user_prompt, :string)` to the schema. Add `:user_prompt` to the `cast/3` fields list.

### Step 3: Update session creation

**`lib/destila/workflows.ex:95-142`** — `create_workflow_session/1`:

- Remove the `{_source_key, _label, dest_key} = creation_config(workflow_type)` call (line 103).
- Add `user_prompt: input_text` to the `session_attrs` map (around line 115-122).
- Remove the `upsert_metadata(ws.id, "creation", dest_key, ...)` call (line 126).

After:
```elixir
session_attrs =
  %{
    title: title,
    workflow_type: workflow_type,
    current_phase: 1,
    total_phases: total_phases(workflow_type),
    title_generating: title_generating,
    user_prompt: input_text
  }
  |> maybe_put(:project_id, project_id)
```

### Step 4: Replace `creation_config/0` with `creation_label/0` and `source_metadata_key/0`

**`lib/destila/workflows/workflow.ex`**:

Remove the `creation_config/0` callback (lines 41-52). Add two new callbacks:

```elixir
@callback creation_label() :: String.t()
@callback source_metadata_key() :: String.t() | nil
```

**`lib/destila/workflows/brainstorm_idea_workflow.ex:29`**:

Replace `def creation_config, do: {nil, "Idea", "idea"}` with:
```elixir
def creation_label, do: "Idea"
def source_metadata_key, do: nil
```

**`lib/destila/workflows/code_chat_workflow.ex:37`**:

Replace `def creation_config, do: {nil, "Prompt", "user_prompt"}` with:
```elixir
def creation_label, do: "Prompt"
def source_metadata_key, do: nil
```

**`lib/destila/workflows/implement_general_prompt_workflow.ex:104`**:

Replace `def creation_config, do: {"prompt_generated", "Prompt", "prompt"}` with:
```elixir
def creation_label, do: "Prompt"
def source_metadata_key, do: "prompt_generated"
```

### Step 5: Update dispatcher functions in workflows.ex

**`lib/destila/workflows.ex`**:

Remove `creation_config/1` (line 43).

Update `list_source_sessions/1` (lines 45-53):
```elixir
def list_source_sessions(workflow_type) do
  source_key = workflow_module(workflow_type).source_metadata_key()

  if source_key do
    list_sessions_with_exported_metadata(source_key)
  else
    []
  end
end
```

Update `creation_label/1` (lines 55-58):
```elixir
def creation_label(workflow_type), do: workflow_module(workflow_type).creation_label()
```

### Step 6: Update system prompt builders to read from session.user_prompt

**`lib/destila/workflows/brainstorm_idea_workflow.ex:84-86`** — `task_description_prompt/1`:

Replace:
```elixir
metadata = Destila.Workflows.get_metadata(workflow_session.id)
idea = get_in(metadata, ["idea", "text"])
```
With:
```elixir
idea = workflow_session.user_prompt
```

**`lib/destila/workflows/code_chat_workflow.ex:50-52`** — `chat_prompt/1`:

Replace:
```elixir
metadata = Destila.Workflows.get_metadata(workflow_session.id)
user_prompt = get_in(metadata, ["user_prompt", "text"])
```
With:
```elixir
user_prompt = workflow_session.user_prompt
```

**`lib/destila/workflows/implement_general_prompt_workflow.ex:122-124`** — `plan_prompt/1`:

Replace:
```elixir
metadata = Destila.Workflows.get_metadata(workflow_session.id)
prompt = get_in(metadata, ["prompt", "text"])
```
With:
```elixir
prompt = workflow_session.user_prompt
```

### Step 7: Update tests

**`test/destila/workflow_test.exs`**:

- Lines 36-38: Remove the `creation_config/0` test for BrainstormIdeaWorkflow. Replace with tests for `creation_label/0` and `source_metadata_key/0`:
  ```elixir
  test "creation_label/0 returns expected label" do
    assert BrainstormIdeaWorkflow.creation_label() == "Idea"
  end

  test "source_metadata_key/0 returns nil" do
    assert BrainstormIdeaWorkflow.source_metadata_key() == nil
  end
  ```

- Lines 60-63: Same for ImplementGeneralPromptWorkflow:
  ```elixir
  test "creation_label/0 returns expected label" do
    assert ImplementGeneralPromptWorkflow.creation_label() == "Prompt"
  end

  test "source_metadata_key/0 returns expected key" do
    assert ImplementGeneralPromptWorkflow.source_metadata_key() == "prompt_generated"
  end
  ```

**`test/destila_web/live/code_chat_workflow_live_test.exs`** — `create_chat_session/1` (lines 28-48):

Remove the `upsert_metadata` call (lines 43-45). Instead, pass `user_prompt` in the `insert_workflow_session` attrs:
```elixir
{:ok, ws} =
  Destila.Workflows.insert_workflow_session(%{
    title: "New Chat",
    workflow_type: :code_chat,
    current_phase: 1,
    total_phases: 1,
    user_prompt: "Help me refactor this module"
  })
```

**`test/destila_web/live/implement_general_prompt_workflow_live_test.exs`** — `create_implement_session/2` (lines 62-86):

Remove the `upsert_metadata` call (lines 81-83). Instead, pass `user_prompt` in the `insert_workflow_session` attrs:
```elixir
{:ok, ws} =
  Destila.Workflows.insert_workflow_session(%{
    title: "Test Implementation",
    workflow_type: :implement_general_prompt,
    project_id: project_id,
    current_phase: phase,
    total_phases: 7,
    title_generating: Keyword.get(opts, :title_generating, true),
    user_prompt: "Implement the login feature"
  })
```

**`test/destila/workflows_metadata_test.exs`**:

- Lines 78-86 ("same key in different phases"): Uses `"idea"` key in creation phase — this test is about general metadata behavior, not user_prompt specifically. Change the key to a non-creation key like `"notes"` so the test remains valid without depending on the now-removed creation metadata pattern.
- Lines 141, 365-366: Tests that create `"idea"` metadata in creation phase for `get_exported_metadata` and `get_metadata` tests — update these to use a different key (e.g., `"notes"`) since the "idea" creation metadata no longer exists.

## Files changed

1. `priv/repo/migrations/<timestamp>_add_user_prompt_to_workflow_sessions.exs` — new migration
2. `lib/destila/workflows/session.ex` — add `user_prompt` field to schema and changeset
3. `lib/destila/workflows.ex` — update `create_workflow_session`, `list_source_sessions`, `creation_label`; remove `creation_config`
4. `lib/destila/workflows/workflow.ex` — replace `creation_config/0` callback with `creation_label/0` and `source_metadata_key/0`
5. `lib/destila/workflows/brainstorm_idea_workflow.ex` — replace `creation_config`, update `task_description_prompt`
6. `lib/destila/workflows/code_chat_workflow.ex` — replace `creation_config`, update `chat_prompt`
7. `lib/destila/workflows/implement_general_prompt_workflow.ex` — replace `creation_config`, update `plan_prompt`
8. `lib/destila_web/live/create_session_live.ex` — update `@moduledoc` reference from `creation_config/0` to `creation_label/0` and `source_metadata_key/0` (line 5)
9. `test/destila/workflow_test.exs` — replace `creation_config` tests
10. `test/destila_web/live/code_chat_workflow_live_test.exs` — use `user_prompt` in session attrs
11. `test/destila_web/live/implement_general_prompt_workflow_live_test.exs` — use `user_prompt` in session attrs
12. `test/destila/workflows_metadata_test.exs` — update keys in tests that used creation-phase prompt keys
