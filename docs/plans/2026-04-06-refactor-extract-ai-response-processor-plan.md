---
title: "refactor: Extract AI.ResponseProcessor"
type: refactor
date: 2026-04-06
---

# refactor: Extract AI.ResponseProcessor

## Overview

`Destila.AI` (332 lines) mixes data access (session/message CRUD) with response processing logic that transforms raw DB data into UI-ready maps. This refactoring extracts all response processing into a new `Destila.AI.ResponseProcessor` module, leaving `AI` as a thin CRUD context (~100 lines).

## Prerequisites

None — this is a pure extraction refactor with no schema or behavior changes.

## Changes

### Step 1: Create `Destila.AI.ResponseProcessor`

**File:** `lib/destila/ai/response_processor.ex`

Create the new module with all response processing functions moved from `lib/destila/ai.ex`:

```elixir
defmodule Destila.AI.ResponseProcessor do
  @moduledoc """
  Transforms raw AI messages and responses into UI-ready maps.

  Handles message processing, session action extraction, tool input parsing,
  and question extraction from MCP tool uses.
  """

  alias Destila.AI.Message

  @session_tool_names ["session", "mcp__destila__session"]

  # --- Public API ---

  @doc """
  Processes a raw message into a display-ready map with derived fields.
  """
  def process_message(%Message{role: :user} = msg, _workflow_session) do
    # ... (move lines 78-91 from ai.ex)
  end

  def process_message(%Message{role: :system, raw_response: raw} = msg, workflow_session)
      when is_map(raw) do
    # ... (move lines 93-135 from ai.ex)
  end

  def process_message(%Message{role: :system} = msg, _workflow_session) do
    # ... (move lines 137-150 from ai.ex)
  end

  @doc """
  Extracts the first session tool call from an AI result or raw_response map.
  """
  def extract_session_action(%{mcp_tool_uses: tool_uses}) when is_list(tool_uses) do
    do_extract_session_action(tool_uses)
  end

  def extract_session_action(%{"mcp_tool_uses" => tool_uses}) when is_list(tool_uses) do
    do_extract_session_action(tool_uses)
  end

  def extract_session_action(_), do: nil

  def response_text(result) do
    # ... (move lines 192-198 from ai.ex)
  end

  # --- Private helpers ---

  defp do_extract_session_action(tool_uses) do
    # ... (move lines 171-180 from ai.ex)
  end

  defp access(map, key) when is_struct(map), do: Map.get(map, key)

  defp access(map, key) when is_map(map) do
    # ... (move lines 185-190 from ai.ex)
  end

  defp derive_message_type(raw, phase, workflow_session) do
    # ... (move lines 240-262 from ai.ex)
    # NOTE: calls extract_session_action/1 — now local
    # NOTE: calls get_phase_def/2 — move this helper too
  end

  defp get_phase_def(workflow_type, phase) do
    Enum.at(Destila.Workflows.phases(workflow_type), phase - 1)
  end

  defp extract_tool_input(%{"mcp_tool_uses" => tool_uses}) when is_list(tool_uses) do
    # ... (move lines 268-276 from ai.ex)
  end

  defp extract_tool_input(_), do: {:text, nil, []}

  defp extract_questions(tool_uses) do
    # ... (move lines 280-305 from ai.ex)
  end

  defp parse_questions(raw, input) when is_binary(raw) do
    # ... (move lines 307-311 from ai.ex)
  end

  defp parse_questions(list, _input) when is_list(list), do: list
  defp parse_questions(_, input), do: [input]
end
```

Functions to move with their visibility:

| Function | Current visibility | New visibility |
|---|---|---|
| `process_message/2` (3 clauses) | public | **public** |
| `extract_session_action/1` (3 clauses) | public | **public** |
| `response_text/1` | public | **public** |
| `do_extract_session_action/1` | private | private |
| `access/2` (2 clauses) | private | private |
| `derive_message_type/4` | private | private |
| `get_phase_def/2` | private | private (move alongside `derive_message_type`) |
| `extract_tool_input/1` (2 clauses) | private | private |
| `extract_questions/1` | private | private |
| `parse_questions/2` (3 clauses) | private | private |
| `@session_tool_names` attribute | module attr | module attr |

### Step 2: Remove moved functions from `Destila.AI`

**File:** `lib/destila/ai.ex`

Delete:
- Lines 70-150: `@doc` + all 3 `process_message/2` clauses
- Line 152: `@session_tool_names` attribute
- Lines 154-180: `@doc` + all `extract_session_action/1` clauses + `do_extract_session_action/1`
- Lines 182-190: `access/2` (both clauses)
- Lines 192-198: `response_text/1`
- Lines 240-266: `derive_message_type/4` + `get_phase_def/2`
- Lines 268-315: `extract_tool_input/1`, `extract_questions/1`, `parse_questions/2`

After deletion, `Destila.AI` should contain only:
- Session CRUD: `get_ai_session_for_workflow/1`, `get_or_create_ai_session/1,2`, `create_ai_session/1`, `update_ai_session/2`
- Message CRUD: `list_messages_for_workflow_session/1`, `create_message/2`
- Title generation: `generate_title/2`, `workflow_type_label/1`
- Helpers: `broadcast/2` delegate, `normalize_keys/1`

### Step 3: Update callers

**3a. `lib/destila/ai/conversation.ex` (line 10, 58-59)**

Current:
```elixir
alias Destila.{AI, Workflows}
...
response_text = AI.response_text(result)
session_action = AI.extract_session_action(result)
```

Change to:
```elixir
alias Destila.{AI, Workflows}
alias Destila.AI.ResponseProcessor
...
response_text = ResponseProcessor.response_text(result)
session_action = ResponseProcessor.extract_session_action(result)
```

**3b. `lib/destila_web/live/workflow_runner_live.ex` (line 19, 266, 410)**

Current:
```elixir
alias Destila.AI
...
processed = AI.process_message(last_system, ws)
```

Change to:
```elixir
alias Destila.AI
alias Destila.AI.ResponseProcessor
...
processed = ResponseProcessor.process_message(last_system, ws)
```

Two call sites: lines 266 and 410.

**3c. `lib/destila_web/components/chat_components.ex` (line 247)**

Current:
```elixir
processed = Destila.AI.process_message(assigns.message, assigns.workflow_session)
```

Change to:
```elixir
# Add alias at top of module:
alias Destila.AI.ResponseProcessor
...
processed = ResponseProcessor.process_message(assigns.message, assigns.workflow_session)
```

### Step 4: Run `mix precommit`

Verify:
- Compilation succeeds with no warnings
- All existing tests pass
- No unused import/alias warnings

## Verification

- `Destila.AI` should be ~100 lines (CRUD + title generation + helpers)
- `Destila.AI.ResponseProcessor` should be ~160 lines (all processing logic)
- No behavior change — pure module extraction
- `mix precommit` passes
