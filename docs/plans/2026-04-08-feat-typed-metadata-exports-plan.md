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

## Key design decisions

### 1. Type validation uses a module attribute allowlist

Define `@valid_metadata_types ~w(text text_file markdown video_file)` in `Destila.Workflows`. Both the MCP tool path (via `conversation.ex`) and `upsert_metadata` validate against this list. Unknown types are rejected — not silently accepted.

### 2. Validation in `upsert_metadata` is the single enforcement point

Rather than scattering validation, `upsert_metadata` validates that the value map's key is one of the allowed types. This covers both the MCP export path and any internal callers. The MCP path additionally validates the `type` field *before* constructing the value map (to return a clear error), but `upsert_metadata` is the backstop.

### 3. The `type` field defaults to `"text"` when omitted

For backward compatibility, when the LLM calls `export` without a `type` field, the system defaults to `"text"`. This means existing prompts and workflows work without modification.

### 4. `list_sessions_with_exported_metadata/1` extracts value from any valid type key

Instead of hardcoding `value["text"]`, it finds the first key in the value map that is a valid type and extracts the value from it. This makes the function work with any type.

### 5. The type is surfaced to the LiveView via the existing value map structure

The `meta.value` map already reaches the template (passed to `metadata_value_block`). The type *is* the key of that map. No new assigns or computed fields are needed — `format_metadata_value/1` pattern-matches on the type key, and future rendering components can do the same.

### 6. No Gherkin scenario changes

This is internal plumbing. The user-facing behavior (metadata appears in sidebar, updates in real-time) is unchanged. All four types render as plain text pass-through for now.

## Changes

### Step 1: Add `type` field to the `:session` tool definition

**File:** `lib/destila/ai/tools.ex`

Add a `type` field to the `:session` tool, between `value` and the closing `end`:

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

Update `do_extract_export_actions/1` (line 163) to include the type in the returned map:

```elixir
# Before (line 163):
[%{key: access(input, :key), value: access(input, :value)}]

# After:
[%{key: access(input, :key), value: access(input, :value), type: access(input, :type)}]
```

When the LLM omits `type`, `access(input, :type)` returns `nil` — the downstream code defaults it to `"text"`.

### Step 3: Add type validation and build typed value map in `conversation.ex`

**File:** `lib/destila/ai/conversation.ex`

**3a. Add a module attribute for valid types (top of module):**

```elixir
@valid_metadata_types ~w(text text_file markdown video_file)
```

**3b. Update the export processing block (lines 87-95):**

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
for %{key: key, value: value, type: type} <- export_actions,
    key != nil,
    type = type || "text",
    type in @valid_metadata_types do
  Workflows.upsert_metadata(
    ws.id,
    phase_name,
    key,
    %{type => value},
    exported: true
  )
end
```

Key details:
- `type = type || "text"` defaults nil to `"text"` (rebinding in generator is valid)
- `type in @valid_metadata_types` silently skips exports with invalid types (malformed LLM output is filtered, not crashed on)
- `%{type => value}` builds the typed value map dynamically instead of hardcoding `"text"`

### Step 4: Add type validation in `upsert_metadata`

**File:** `lib/destila/workflows.ex`

**4a. Add a module attribute for valid types (near the top, after imports):**

```elixir
@valid_metadata_types ~w(text text_file markdown video_file)
```

**4b. Add a validation guard at the top of `upsert_metadata/5` (line 230):**

```elixir
def upsert_metadata(workflow_session_id, phase_name, key, value, opts \\ [])

def upsert_metadata(workflow_session_id, phase_name, key, value, opts)
    when is_map(value) do
  # Validate that the value map's key is a valid metadata type (if it looks like a typed value)
  # Non-typed value maps (like %{"id" => ...} for source_session) pass through
  value_keys = Map.keys(value)

  if length(value_keys) == 1 and hd(value_keys) not in @valid_metadata_types ++ ["id"] do
    {:error, :invalid_metadata_type}
  else
    exported = Keyword.get(opts, :exported, false)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # ... rest of existing implementation unchanged
  end
end
```

Wait — this approach is overly complex. The existing `upsert_metadata` already accepts arbitrary value maps (like `%{"id" => session_id}` for source_session metadata, and `%{"status" => "done"}` for internal metadata). Adding type validation here would require distinguishing "typed export values" from "arbitrary internal metadata maps."

**Revised approach:** Only validate for exported metadata. When `exported: true` is passed, enforce that the value map contains exactly one key that is a valid metadata type. When `exported: false` (the default), pass through without type validation.

```elixir
def upsert_metadata(workflow_session_id, phase_name, key, value, opts \\ []) do
  exported = Keyword.get(opts, :exported, false)

  if exported and not valid_exported_value?(value) do
    {:error, :invalid_metadata_type}
  else
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # ... existing insert logic unchanged
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

This validates that exported metadata has exactly one key and it's a valid type. Non-exported metadata (creation metadata, internal state) is unaffected.

### Step 5: Update `list_sessions_with_exported_metadata/1`

**File:** `lib/destila/workflows.ex`

Update line 183 to extract the value from any valid type key, not just `"text"`:

```elixir
# Before (line 183):
|> Enum.map(fn {ws, value} -> {ws, value["text"]} end)

# After:
|> Enum.map(fn {ws, value} -> {ws, extract_metadata_text(value)} end)
```

**Add a helper function:**

```elixir
@doc false
defp extract_metadata_text(value) when is_map(value) do
  Enum.find_value(@valid_metadata_types, fn type -> value[type] end)
end

defp extract_metadata_text(_), do: nil
```

This tries each valid type key in order (`text` first, then `text_file`, `markdown`, `video_file`) and returns the first non-nil value. Since typed value maps have exactly one key, the order doesn't matter — but `text` being first means existing data is found on the first try.

### Step 6: Update `format_metadata_value/1` in the LiveView

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

### Step 7: Update `@tool_instructions` and `@non_interactive_tool_instructions`

**File:** `lib/destila/workflows/brainstorm_idea_workflow.ex`

Update the "Exporting Data" section in `@tool_instructions` to document the `type` parameter:

```elixir
## Exporting Data

To store a key-value pair as session metadata, call `mcp__destila__session` with \
`action: "export"`, a `key` string, and a `value` string. You may call export \
multiple times in a single response and may combine it with a phase transition action.

You can optionally specify a `type` string to indicate how the value should be \
interpreted: `text` (default), `text_file` (absolute path to a text file), \
`markdown` (markdown content), or `video_file` (absolute path to a video file).
```

**File:** `lib/destila/workflows/implement_general_prompt_workflow.ex`

Apply the same update to `@non_interactive_tool_instructions`.

### Step 8: Add tests

**File:** `test/destila/workflows_metadata_test.exs`

**8a. Add tests for type validation in `upsert_metadata`:**

```elixir
describe "upsert_metadata/5 type validation" do
  test "accepts valid metadata types for exported metadata" do
    ws = insert_workflow_session()

    for type <- ~w(text text_file markdown video_file) do
      assert {:ok, _} =
               Workflows.upsert_metadata(
                 ws.id, "phase", "key_#{type}", %{type => "value"},
                 exported: true
               )
    end
  end

  test "rejects invalid type for exported metadata" do
    ws = insert_workflow_session()

    assert {:error, :invalid_metadata_type} =
             Workflows.upsert_metadata(
               ws.id, "phase", "key", %{"invalid_type" => "value"},
               exported: true
             )
  end

  test "allows arbitrary value maps for non-exported metadata" do
    ws = insert_workflow_session()

    assert {:ok, _} =
             Workflows.upsert_metadata(
               ws.id, "creation", "source_session", %{"id" => "some-uuid"}
             )
  end
end
```

**8b. Add test for `list_sessions_with_exported_metadata` with non-text types:**

```elixir
test "returns value for non-text metadata types" do
  ws = insert_workflow_session(%{done_at: DateTime.utc_now()})

  Workflows.upsert_metadata(
    ws.id, "phase", "my_export", %{"markdown" => "# Hello"},
    exported: true
  )

  result = Workflows.list_sessions_with_exported_metadata("my_export")
  assert [{^ws_id, "# Hello"}] = [{elem(hd(result), 0).id, elem(hd(result), 1)}]
end
```

**File:** `test/destila/ai/response_processor_test.exs` (or relevant test file)

**8c. Add test for type extraction in `extract_export_actions`:**

```elixir
test "extracts type from export actions" do
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
```

**File:** `test/destila/executions/engine_test.exs`

**8d. Add engine integration test for typed exports:**

```elixir
test "stores typed metadata from AI export action" do
  ws = create_session_with_ai(%{pe_status: :processing})

  Engine.phase_update(ws.id, 1, %{
    ai_result: %{
      text: "Here is markdown output",
      result: "Here is markdown output",
      mcp_tool_uses: [
        %{
          name: "mcp__destila__session",
          input: %{
            action: "export",
            key: "plan_doc",
            value: "# Plan\nDo the thing",
            type: "markdown"
          }
        }
      ]
    }
  })

  all_metadata = Workflows.get_all_metadata(ws.id)
  exported = Enum.find(all_metadata, &(&1.key == "plan_doc"))
  assert exported != nil
  assert exported.value == %{"markdown" => "# Plan\nDo the thing"}
  assert exported.exported == true
end

test "defaults to text type when type is omitted" do
  ws = create_session_with_ai(%{pe_status: :processing})

  Engine.phase_update(ws.id, 1, %{
    ai_result: %{
      text: "Output",
      result: "Output",
      mcp_tool_uses: [
        %{
          name: "mcp__destila__session",
          input: %{action: "export", key: "result", value: "plain text"}
        }
      ]
    }
  })

  all_metadata = Workflows.get_all_metadata(ws.id)
  exported = Enum.find(all_metadata, &(&1.key == "result"))
  assert exported.value == %{"text" => "plain text"}
end

test "skips export with invalid type" do
  ws = create_session_with_ai(%{pe_status: :processing})

  Engine.phase_update(ws.id, 1, %{
    ai_result: %{
      text: "Output",
      result: "Output",
      mcp_tool_uses: [
        %{
          name: "mcp__destila__session",
          input: %{action: "export", key: "bad", value: "v", type: "html"}
        }
      ]
    }
  })

  all_metadata = Workflows.get_all_metadata(ws.id)
  assert all_metadata == []
end
```

### Step 9: Run `mix precommit`

Verify compilation, formatting, and tests pass.

## What does NOT change

- **Database schema**: No migration. The `value` map column already stores arbitrary maps. The type is encoded as the key of the map.
- **Existing data**: All existing `%{"text" => value}` entries are automatically backward-compatible — `"text"` is a valid type.
- **Creation metadata**: `create_workflow_session/1` (line 119) stores `%{"text" => input_text}` — this is the `text` type, already valid.
- **Internal metadata**: Non-exported metadata like `%{"id" => session_id}` and `%{"status" => "done"}` are not validated (only exported metadata is type-checked).
- **Gherkin feature files**: No scenario changes. This is internal plumbing.
- **Rendering**: All four types render as plain text for now. Specialized rendering components will be built separately.
- **`metadata_value_block/1`**: The function component structure stays the same — it calls `format_metadata_value/1` which now handles all four types.

## Execution order

1. Step 1 (tool definition) — add `type` field to `:session` tool
2. Step 2 (ResponseProcessor) — extract `type` from export actions
3. Steps 3-4 (Conversation + Workflows) — build typed value maps and validate
4. Step 5 (Workflows) — update `list_sessions_with_exported_metadata`
5. Step 6 (LiveView) — expand `format_metadata_value` for all types
6. Step 7 (tool instructions) — document the `type` parameter
7. Step 8 (tests) — verify type extraction, validation, persistence, and display
8. Step 9 (precommit) — validate

## Files modified

- `lib/destila/ai/tools.ex` — add `type` field to `:session` tool
- `lib/destila/ai/response_processor.ex` — extract `type` in `do_extract_export_actions`
- `lib/destila/ai/conversation.ex` — build `%{type => value}` map, validate type
- `lib/destila/workflows.ex` — validate exported metadata type, update `list_sessions_with_exported_metadata`, add `extract_metadata_text` helper
- `lib/destila_web/live/workflow_runner_live.ex` — expand `format_metadata_value` for all four types
- `lib/destila/workflows/brainstorm_idea_workflow.ex` — update `@tool_instructions`
- `lib/destila/workflows/implement_general_prompt_workflow.ex` — update `@non_interactive_tool_instructions`
- `test/destila/workflows_metadata_test.exs` — type validation tests
- `test/destila/executions/engine_test.exs` — typed export integration tests
- `test/destila/ai/response_processor_test.exs` — type extraction tests

## Done when

- The `:session` tool accepts an optional `type` field for export actions
- `extract_export_actions/1` returns `%{key: ..., value: ..., type: ...}` maps
- `conversation.ex` builds `%{type => value}` instead of hardcoded `%{"text" => value}`
- Unknown types are rejected in both the export path and `upsert_metadata` (for exported metadata)
- `list_sessions_with_exported_metadata/1` extracts values from any valid type key
- `format_metadata_value/1` pattern-matches on all four type keys
- Type defaults to `"text"` when omitted by the LLM
- Existing `%{"text" => value}` data is fully backward-compatible
- No database migration needed
- All tests pass, `mix precommit` passes
