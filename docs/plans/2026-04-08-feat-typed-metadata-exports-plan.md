---
title: "feat: Add typed metadata exports to the workflow system"
type: feat
date: 2026-04-08
---

# feat: Add typed metadata exports to the workflow system

## Overview

Currently, all exported metadata values are stored as `%{"text" => value}` — a map with a single `"text"` key. This change extends the system so the LLM (via the MCP `session` tool's `export` action) and internal code (via `upsert_metadata`) can specify a type for each export. The type determines how the value should be interpreted and, eventually, rendered.

The supported types are: `text` (default), `text_file`, `markdown`, and `video_file`. The type is encoded as the key of the value map itself:

- `%{"text" => "hello world"}` — plain text (backward-compatible with all existing data)
- `%{"markdown" => "# Title\nSome content"}` — markdown content
- `%{"text_file" => "/absolute/path/to/file.txt"}` — path to a text file on disk
- `%{"video_file" => "/absolute/path/to/video.mp4"}` — path to a video file on disk

No database migration is needed — the existing `value` map column already supports this. Existing `%{"text" => value}` data is automatically backward-compatible as the `text` type.

## Current state

- **Tool definition** (`lib/destila/ai/tools.ex:42-70`): The `:session` tool has `action`, `message`, `key`, and `value` fields. No `type` field exists.
- **Export extraction** (`lib/destila/ai/response_processor.ex:155-171`): `do_extract_export_actions/1` returns `%{key: key, value: value}` maps — no type extracted.
- **Value wrapping** (`lib/destila/ai/conversation.ex:92`): Hardcoded `%{"text" => value}` for all exports.
- **Metadata persistence** (`lib/destila/workflows.ex:230-255`): `upsert_metadata/5` accepts an opaque `value` map and passes it through. No type validation.
- **Metadata listing** (`lib/destila/workflows.ex:183`): `list_sessions_with_exported_metadata/1` extracts `value["text"]` — only recognizes the `text` type.
- **Metadata display** (`lib/destila_web/live/workflow_runner_live.ex:763-765`): `format_metadata_value/1` pattern-matches `%{"text" => text}`, falls back to JSON for other maps.
- **Creation metadata** (`lib/destila/workflows.ex:119`): `create_workflow_session/1` stores creation metadata as `%{"text" => input_text}` — these are internal (not AI exports) and use the `text` type correctly.
- **Workflow prompt reads** — three workflows read creation metadata via `get_in(metadata, ["key", "text"])`:
  - `brainstorm_idea_workflow.ex:86` — `get_in(metadata, ["idea", "text"])`
  - `implement_general_prompt_workflow.ex:120` — `get_in(metadata, ["prompt", "text"])`
  - `code_chat_workflow.ex:52` — `get_in(metadata, ["user_prompt", "text"])`

  These all read non-exported creation metadata which is always `%{"text" => value}`, so they do not need changes.

## Key design decisions

### 1. Single source of truth for valid types in `Destila.Workflows`

Define `@valid_metadata_types ~w(text text_file markdown video_file)` as a module attribute in `Destila.Workflows` alongside a public function `valid_metadata_types/0` that returns the list. `Conversation` calls `Workflows.valid_metadata_types()` rather than duplicating the allowlist. This ensures adding a new type only requires a one-line change.

### 2. Validation in `upsert_metadata` only applies to exported metadata

The existing `upsert_metadata/5` accepts arbitrary value maps for internal metadata (e.g., `%{"id" => session_id}` for source_session, `%{"status" => "done"}` for title_gen). Type validation only triggers when `exported: true` is passed — it enforces that the value map contains exactly one key that is a valid metadata type. Non-exported metadata passes through without type validation.

### 3. The `type` field defaults to `"text"` when omitted

For backward compatibility, when the LLM calls `export` without a `type` field, the system defaults to `"text"`. This means existing prompts and workflows work without modification.

### 4. `list_sessions_with_exported_metadata/1` extracts value from any valid type key

Instead of hardcoding `value["text"]`, it finds the first key in the value map that is a valid type and extracts the value from it. Since typed value maps have exactly one key, the order of iteration doesn't matter functionally — but trying `text` first optimizes for existing data.

### 5. The type is surfaced to the LiveView via the existing value map structure

The `meta.value` map already reaches the template (passed to `metadata_value_block`). The type *is* the key of that map. No new assigns or computed fields are needed — `format_metadata_value/1` pattern-matches on the type key, and future rendering components can do the same.

### 6. Invalid types are silently filtered in the export path, validated in `upsert_metadata`

In `conversation.ex`, the `for` comprehension's `type in valid_types` filter silently skips exports with invalid types — this is the right behavior for malformed LLM output (don't crash, just skip). In `upsert_metadata`, the validation returns `{:error, :invalid_metadata_type}` — this is the backstop for programmatic callers who should know better.

### 7. No Gherkin scenario changes

This is internal plumbing. The user-facing behavior (metadata appears in sidebar, updates in real-time) is unchanged. All four types render as plain text pass-through for now.

## Changes

### Step 1: Add `type` field to the `:session` tool definition

**File:** `lib/destila/ai/tools.ex`

Add a `type` field to the `:session` tool, between the `value` field (line 63) and the closing `end`:

```elixir
field(:type, :string,
  description:
    "Type of the exported value. One of: text (default), text_file, markdown, video_file. " <>
      "Determines how the value is interpreted and rendered."
)
```

The field is optional — when omitted, the system defaults to `"text"`.

### Step 2: Extract `type` in `ResponseProcessor.extract_export_actions/1`

**File:** `lib/destila/ai/response_processor.ex`

Update `do_extract_export_actions/1` at line 163 to include the type in the returned map:

```elixir
# Before (line 163):
[%{key: access(input, :key), value: access(input, :value)}]

# After:
[%{key: access(input, :key), value: access(input, :value), type: access(input, :type)}]
```

When the LLM omits `type`, `access(input, :type)` returns `nil` — the downstream code defaults it to `"text"`.

Also update the `@doc` for `extract_export_actions/1` (line 117):

```elixir
# Before:
Returns a list of `%{key: key, value: value}` maps.

# After:
Returns a list of `%{key: key, value: value, type: type}` maps. Type is `nil` when omitted.
```

### Step 3: Add valid types to `Destila.Workflows` and expose via public function

**File:** `lib/destila/workflows.ex`

Add near the top of the module (after `alias` statements):

```elixir
@valid_metadata_types ~w(text text_file markdown video_file)

@doc """
Returns the list of valid metadata types for exported metadata values.
"""
def valid_metadata_types, do: @valid_metadata_types
```

### Step 4: Add type validation in `upsert_metadata`

**File:** `lib/destila/workflows.ex`

Restructure `upsert_metadata/5` (lines 230-255) to validate exported metadata types. Since we're adding a head with a default value and a second clause, we need a function head:

```elixir
def upsert_metadata(workflow_session_id, phase_name, key, value, opts \\ [])

def upsert_metadata(workflow_session_id, phase_name, key, value, opts) do
  exported = Keyword.get(opts, :exported, false)

  if exported and not valid_exported_value?(value) do
    {:error, :invalid_metadata_type}
  else
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %SessionMetadata{}
    |> SessionMetadata.changeset(%{
      workflow_session_id: workflow_session_id,
      phase_name: phase_name,
      key: key,
      value: value,
      exported: exported
    })
    |> Repo.insert(
      on_conflict: {:replace, [:value, :exported, :updated_at]},
      conflict_target: [:workflow_session_id, :phase_name, :key],
      set: [updated_at: now]
    )
    |> case do
      {:ok, metadata} ->
        Destila.PubSubHelper.broadcast_event(:metadata_updated, workflow_session_id)
        {:ok, metadata}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end

defp valid_exported_value?(value) when is_map(value) do
  case Map.keys(value) do
    [type] -> type in @valid_metadata_types
    _ -> false
  end
end

defp valid_exported_value?(_), do: false
```

**Why only validate exported metadata**: Non-exported metadata uses arbitrary value maps like `%{"id" => session_id}` (source_session at line 122) and `%{"status" => "done"}` (historical title_gen). These are internal and don't represent typed content. The `exported: true` flag reliably distinguishes AI exports from internal metadata.

### Step 5: Build typed value map in `conversation.ex`

**File:** `lib/destila/ai/conversation.ex`

Update the export processing block (lines 87-95):

```elixir
# Before (lines 87-95):
for %{key: key, value: value} <- export_actions, key != nil do
  Workflows.upsert_metadata(
    ws.id,
    phase_name,
    key,
    %{"text" => value},
    exported: true
  )
end

# After:
valid_types = Workflows.valid_metadata_types()

for %{key: key, value: value, type: type} <- export_actions,
    key != nil,
    type = type || "text",
    type in valid_types do
  Workflows.upsert_metadata(
    ws.id,
    phase_name,
    key,
    %{type => value},
    exported: true
  )
end
```

**How the `for` generators work:**

- `%{key: key, value: value, type: type} <- export_actions` — destructures each export action
- `key != nil` — filter: skips malformed exports with nil key
- `type = type || "text"` — generator that rebinds `type`, defaulting `nil` to `"text"`. In Elixir `for` comprehensions, `=` in a generator always matches (it's a pattern match that can also rebind), so this never filters — it transforms.
- `type in valid_types` — filter: silently skips exports with invalid types

**Why filter instead of error**: The LLM may produce malformed output. Silently skipping invalid types is safer than crashing. The `upsert_metadata` validation (Step 4) is the backstop for programmatic callers.

### Step 6: Update `list_sessions_with_exported_metadata/1`

**File:** `lib/destila/workflows.ex`

Update line 183 to extract the value from any valid type key:

```elixir
# Before (line 183):
|> Enum.map(fn {ws, value} -> {ws, value["text"]} end)

# After:
|> Enum.map(fn {ws, value} -> {ws, extract_metadata_text(value)} end)
```

Add the helper after `list_sessions_with_exported_metadata/1`:

```elixir
defp extract_metadata_text(value) when is_map(value) do
  Enum.find_value(@valid_metadata_types, fn type -> value[type] end)
end

defp extract_metadata_text(_), do: nil
```

This iterates `@valid_metadata_types` in definition order (`text` first) and returns the first non-nil value. Since typed value maps have exactly one key, only one iteration will match.

### Step 7: Update `format_metadata_value/1` in the LiveView

**File:** `lib/destila_web/live/workflow_runner_live.ex`

Expand `format_metadata_value/1` (lines 763-765) to pattern-match on all four type keys:

```elixir
# Before:
defp format_metadata_value(%{"text" => text}) when is_binary(text), do: text
defp format_metadata_value(value) when is_map(value), do: Jason.encode!(value, pretty: true)
defp format_metadata_value(value), do: inspect(value)

# After:
defp format_metadata_value(%{"text" => text}) when is_binary(text), do: text
defp format_metadata_value(%{"markdown" => md}) when is_binary(md), do: md
defp format_metadata_value(%{"text_file" => path}) when is_binary(path), do: path
defp format_metadata_value(%{"video_file" => path}) when is_binary(path), do: path
defp format_metadata_value(value) when is_map(value), do: Jason.encode!(value, pretty: true)
defp format_metadata_value(value), do: inspect(value)
```

All four types render as plain text pass-through for now. Specialized rendering components (markdown rendering, file preview, video player) will be added later and will dispatch on the type key in `metadata_value_block/1`.

### Step 8: Update tool instructions in all three workflows

**8a. File:** `lib/destila/workflows/brainstorm_idea_workflow.ex`

Update the "Exporting Data" section in `@tool_instructions` (line 48) to document the `type` parameter:

```elixir
## Exporting Data

To store a key-value pair as session metadata, call `mcp__destila__session` with \
`action: "export"`, a `key` string, and a `value` string. You may call export \
multiple times in a single response and may combine it with a phase transition action.

You can optionally specify a `type` string to indicate how the value should be \
interpreted: `text` (default), `text_file` (absolute path to a text file), \
`markdown` (markdown content), or `video_file` (absolute path to a video file).
```

**8b. File:** `lib/destila/workflows/implement_general_prompt_workflow.ex`

Apply the same update to the "Exporting Data" section in `@non_interactive_tool_instructions` (line 36).

**8c. File:** `lib/destila/workflows/code_chat_workflow.ex`

Update the inline export instructions at lines 82-83:

```elixir
# Before (lines 82-83):
To store a key-value pair as session metadata, call `mcp__destila__session` with \
`action: "export"`, a `key` string, and a `value` string.

# After:
To store a key-value pair as session metadata, call `mcp__destila__session` with \
`action: "export"`, a `key` string, and a `value` string. You can optionally \
specify a `type` string: `text` (default), `text_file`, `markdown`, or `video_file`.
```

### Step 9: Add tests

**9a. File:** `test/destila/workflows_metadata_test.exs`

Add a new `describe` block for type validation in `upsert_metadata`:

```elixir
describe "upsert_metadata/5 type validation for exported metadata" do
  test "accepts all valid metadata types" do
    ws = create_session()

    for type <- ~w(text text_file markdown video_file) do
      assert {:ok, _} =
               Workflows.upsert_metadata(
                 ws.id, "phase", "key_#{type}", %{type => "value"},
                 exported: true
               )
    end
  end

  test "rejects invalid type for exported metadata" do
    ws = create_session()

    assert {:error, :invalid_metadata_type} =
             Workflows.upsert_metadata(
               ws.id, "phase", "key", %{"html" => "<p>bad</p>"},
               exported: true
             )
  end

  test "rejects multi-key value maps for exported metadata" do
    ws = create_session()

    assert {:error, :invalid_metadata_type} =
             Workflows.upsert_metadata(
               ws.id, "phase", "key", %{"text" => "a", "extra" => "b"},
               exported: true
             )
  end

  test "allows arbitrary value maps for non-exported metadata" do
    ws = create_session()

    assert {:ok, _} =
             Workflows.upsert_metadata(
               ws.id, "creation", "source_session", %{"id" => "some-uuid"}
             )
  end
end
```

**9b.** Add a test inside the existing `describe "list_sessions_with_exported_metadata/1"` block:

```elixir
test "returns value for non-text metadata types" do
  ws = create_session()
  {:ok, _} = Workflows.update_workflow_session(ws, %{done_at: DateTime.utc_now()})

  Workflows.upsert_metadata(
    ws.id, "phase", "my_doc", %{"markdown" => "# Hello"},
    exported: true
  )

  result = Workflows.list_sessions_with_exported_metadata("my_doc")
  assert [{session, text}] = result
  assert session.id == ws.id
  assert text == "# Hello"
end
```

**9c. File:** `test/destila/ai/response_processor_test.exs` (**new file** — no ResponseProcessor tests exist yet)

```elixir
defmodule Destila.AI.ResponseProcessorTest do
  use ExUnit.Case, async: true

  alias Destila.AI.ResponseProcessor

  describe "extract_export_actions/1" do
    test "extracts type from export actions (atom keys)" do
      result = %{
        mcp_tool_uses: [
          %{
            name: "mcp__destila__session",
            input: %{action: "export", key: "doc", value: "# Title", type: "markdown"}
          }
        ]
      }

      assert [%{key: "doc", value: "# Title", type: "markdown"}] =
               ResponseProcessor.extract_export_actions(result)
    end

    test "extracts type from export actions (string keys)" do
      result = %{
        "mcp_tool_uses" => [
          %{
            "name" => "mcp__destila__session",
            "input" => %{
              "action" => "export",
              "key" => "doc",
              "value" => "# Title",
              "type" => "markdown"
            }
          }
        ]
      }

      assert [%{key: "doc", value: "# Title", type: "markdown"}] =
               ResponseProcessor.extract_export_actions(result)
    end

    test "type is nil when omitted" do
      result = %{
        mcp_tool_uses: [
          %{
            name: "mcp__destila__session",
            input: %{action: "export", key: "doc", value: "plain text"}
          }
        ]
      }

      assert [%{key: "doc", value: "plain text", type: nil}] =
               ResponseProcessor.extract_export_actions(result)
    end

    test "extracts multiple exports with different types" do
      result = %{
        mcp_tool_uses: [
          %{
            name: "mcp__destila__session",
            input: %{action: "export", key: "summary", value: "text", type: "text"}
          },
          %{
            name: "mcp__destila__session",
            input: %{action: "export", key: "doc", value: "# MD", type: "markdown"}
          }
        ]
      }

      exports = ResponseProcessor.extract_export_actions(result)
      assert length(exports) == 2
      assert Enum.at(exports, 0).type == "text"
      assert Enum.at(exports, 1).type == "markdown"
    end

    test "ignores non-export session actions" do
      result = %{
        mcp_tool_uses: [
          %{
            name: "mcp__destila__session",
            input: %{action: "phase_complete", message: "done"}
          }
        ]
      }

      assert [] = ResponseProcessor.extract_export_actions(result)
    end
  end
end
```

**Note on integration tests**: There is no existing `engine_test.exs` — the `handle_ai_result/2` function is called from `SessionProcess` (a `gen_statem`) and is not directly tested in isolation. The typed export behavior is fully covered by:
- Unit tests on `ResponseProcessor.extract_export_actions/1` (type extraction)
- Unit tests on `Workflows.upsert_metadata/5` (type validation)
- Unit tests on `Workflows.list_sessions_with_exported_metadata/1` (type-aware value extraction)

The `for` comprehension logic in `conversation.ex` (defaulting nil → "text", filtering invalid types) is thin glue. If desired, a `Conversation` test can be added later, but it would require setting up an AI session and workflow session — heavyweight for testing three lines of `for` logic.

### Step 10: Run `mix precommit`

Verify compilation, formatting, and tests pass.

## What does NOT change

- **Database schema**: No migration. The `value` map column already stores arbitrary maps. The type is encoded as the key of the map.
- **Existing data**: All existing `%{"text" => value}` entries are automatically backward-compatible — `"text"` is a valid type.
- **Creation metadata**: `create_workflow_session/1` (line 119) stores `%{"text" => input_text}` — this is the `text` type, already valid.
- **Internal metadata**: Non-exported metadata like `%{"id" => session_id}` and `%{"status" => "done"}` are not validated (only exported metadata is type-checked).
- **Workflow prompt reads**: `get_in(metadata, ["idea", "text"])`, `get_in(metadata, ["prompt", "text"])`, and `get_in(metadata, ["user_prompt", "text"])` all read non-exported creation metadata which is always `%{"text" => value}`. These do not change.
- **Gherkin feature files**: No scenario changes. This is internal plumbing.
- **Rendering**: All four types render as plain text for now. Specialized rendering components will be built separately.
- **`metadata_value_block/1`**: The function component structure stays the same — it calls `format_metadata_value/1` which now handles all four types.

## Execution order

1. Step 1 (tool definition) — add `type` field to `:session` tool
2. Step 2 (ResponseProcessor) — extract `type` from export actions
3. Steps 3-4 (Workflows) — add valid types list, validate in `upsert_metadata`
4. Step 5 (Conversation) — build typed value maps using `Workflows.valid_metadata_types()`
5. Step 6 (Workflows) — update `list_sessions_with_exported_metadata`
6. Step 7 (LiveView) — expand `format_metadata_value` for all types
7. Step 8 (tool instructions) — document `type` in all three workflows
8. Step 9 (tests) — verify type extraction, validation, persistence, and display
9. Step 10 (precommit) — validate

## Files modified

- `lib/destila/ai/tools.ex` — add `type` field to `:session` tool
- `lib/destila/ai/response_processor.ex` — extract `type` in `do_extract_export_actions`
- `lib/destila/workflows.ex` — add `@valid_metadata_types`, `valid_metadata_types/0`, `valid_exported_value?/1`, `extract_metadata_text/1`; validate in `upsert_metadata`; update `list_sessions_with_exported_metadata`
- `lib/destila/ai/conversation.ex` — build `%{type => value}` map, filter invalid types
- `lib/destila_web/live/workflow_runner_live.ex` — expand `format_metadata_value` for all four types
- `lib/destila/workflows/brainstorm_idea_workflow.ex` — update `@tool_instructions`
- `lib/destila/workflows/implement_general_prompt_workflow.ex` — update `@non_interactive_tool_instructions`
- `lib/destila/workflows/code_chat_workflow.ex` — update inline export instructions
- `test/destila/workflows_metadata_test.exs` — type validation and typed listing tests
- `test/destila/ai/response_processor_test.exs` — **new file**, type extraction tests

## Done when

- The `:session` tool accepts an optional `type` field for export actions
- `extract_export_actions/1` returns `%{key: ..., value: ..., type: ...}` maps
- `Workflows.valid_metadata_types/0` is the single source of truth for allowed types
- `conversation.ex` builds `%{type => value}` instead of hardcoded `%{"text" => value}`
- Unknown types are filtered in the export path and rejected in `upsert_metadata` (for exported metadata)
- `list_sessions_with_exported_metadata/1` extracts values from any valid type key
- `format_metadata_value/1` pattern-matches on all four type keys
- Type defaults to `"text"` when omitted by the LLM
- All three workflow tool instructions document the `type` parameter
- Existing `%{"text" => value}` data is fully backward-compatible
- No database migration needed
- All tests pass, `mix precommit` passes
