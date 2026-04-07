---
title: "refactor: Move session_opts_for_workflow to SessionConfig"
type: refactor
date: 2026-04-06
---

# refactor: Move session_opts_for_workflow to SessionConfig

## Overview

`Destila.AI.ClaudeSession` is a GenServer responsible for session lifecycle and streaming. It currently contains `session_opts_for_workflow/3` and `merge_phase_opts/2`, which reach upward into `Destila.Workflows.phases/1` and `Destila.AI.get_ai_session_for_workflow/1` — domain-layer dependencies that don't belong in infrastructure. This refactoring extracts those two functions into a new `Destila.AI.SessionConfig` module.

## Prerequisites

None — pure extraction refactor with no schema or behavior changes.

## Changes

### Step 1: Create `Destila.AI.SessionConfig`

**File:** `lib/destila/ai/session_config.ex`

Create a new module with the two functions moved from `ClaudeSession`:

```elixir
defmodule Destila.AI.SessionConfig do
  @moduledoc """
  Resolves ClaudeCode session options for a workflow session and phase.

  Reads phase definitions and AI session records to build the option keyword
  list passed to `ClaudeSession.start_link/1`.
  """

  @doc """
  Builds ClaudeCode session options for a workflow session and phase.

  Resolves the session strategy from the workflow module, adds `:resume`
  and `:cwd` from the AI session record, and merges any phase-provided options.

  Additional base options (e.g. `timeout_ms`) can be passed and will be included.
  """
  def session_opts_for_workflow(workflow_session, phase, base_opts \\ []) do
    # Moved verbatim from ClaudeSession lines 149-187
    phase_def = Enum.at(Destila.Workflows.phases(workflow_session.workflow_type), phase - 1)

    strategy_opts =
      case phase_def do
        %Destila.Workflows.Phase{session_strategy: {_action, opts}} -> opts
        _ -> []
      end

    ai_session = Destila.AI.get_ai_session_for_workflow(workflow_session.id)

    opts = base_opts

    opts =
      if ai_session && ai_session.claude_session_id do
        Keyword.put(opts, :resume, ai_session.claude_session_id)
      else
        opts
      end

    opts =
      if ai_session && ai_session.worktree_path do
        Keyword.put(opts, :cwd, ai_session.worktree_path)
      else
        opts
      end

    opts =
      case phase_def do
        %Destila.Workflows.Phase{allowed_tools: tools} when tools != [] ->
          Keyword.put(opts, :allowed_tools, tools)

        _ ->
          opts
      end

    merge_phase_opts(opts, strategy_opts)
  end

  @doc """
  Merges phase-provided ClaudeCode options with base session options.
  MCP servers are map-merged; all other options use standard keyword merge.
  """
  def merge_phase_opts(base_opts, phase_opts) do
    # Moved verbatim from ClaudeSession lines 193-206
    {phase_mcp, phase_rest} = Keyword.pop(phase_opts, :mcp_servers, %{})
    {base_mcp, base_rest} = Keyword.pop(base_opts, :mcp_servers, %{})

    merged = Keyword.merge(base_rest, phase_rest)
    merged_mcp = Map.merge(base_mcp, phase_mcp)

    if merged_mcp == %{} do
      merged
    else
      Keyword.put(merged, :mcp_servers, merged_mcp)
    end
  end
end
```

### Step 2: Remove functions from `ClaudeSession`

**File:** `lib/destila/ai/claude_session.ex`

Delete lines 141–206 (the `@doc` block, `session_opts_for_workflow/3`, its `@doc`, and `merge_phase_opts/2`). This removes the upward dependencies on `Destila.Workflows` and `Destila.AI`.

### Step 3: Update caller in `AiQueryWorker`

**File:** `lib/destila/workers/ai_query_worker.ex` — line 22

Change:

```elixir
session_opts = AI.ClaudeSession.session_opts_for_workflow(ws, phase)
```

to:

```elixir
session_opts = Destila.AI.SessionConfig.session_opts_for_workflow(ws, phase)
```

### Step 4: Verify no other callers

The grep confirms only one call site (`ai_query_worker.ex:22`). No tests directly call `ClaudeSession.session_opts_for_workflow/3` or `ClaudeSession.merge_phase_opts/2`.

### Step 5: Run `mix precommit`

Ensure compilation, tests, and formatting pass.

## Verification

- `ClaudeSession` has no references to `Destila.Workflows.phases/1` or `Destila.AI.get_ai_session_for_workflow/1`
- `SessionConfig.session_opts_for_workflow/3` and `SessionConfig.merge_phase_opts/2` are public
- `AiQueryWorker` calls `SessionConfig` instead of `ClaudeSession`
- All tests pass

## Files touched

| File | Action |
|------|--------|
| `lib/destila/ai/session_config.ex` | Create — new module with extracted functions |
| `lib/destila/ai/claude_session.ex` | Remove `session_opts_for_workflow/3` and `merge_phase_opts/2` |
| `lib/destila/workers/ai_query_worker.ex` | Update call site to use `SessionConfig` |
