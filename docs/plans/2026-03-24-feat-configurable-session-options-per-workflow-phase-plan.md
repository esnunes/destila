---
title: "feat: Configurable Claude Code Session Options per Workflow Phase"
type: feat
date: 2026-03-24
---

# feat: Configurable Claude Code Session Options per Workflow Phase

## Overview

Add a mechanism for workflow phase modules to define ClaudeCode session configuration on a per-phase basis. Currently all AI sessions start with a hardcoded restricted tool set (`Read`, `Grep`, `Glob`, limited `Bash`) and only the Destila MCP server. This change makes session configuration driven by the workflow phase module, enabling future workflows (e.g. code implementation) to opt into full Claude Code access with `dangerously_skip_permissions: true`.

## Problem Statement / Motivation

The existing system cannot support workflow types that need different levels of AI capability per phase. A future "implement" workflow needs full Claude Code access (file editing, arbitrary Bash, project MCP servers) while the current "chore task" workflow only needs read-only codebase access. The configuration is hardcoded in `Session.init/1` and cannot vary by workflow type or phase.

## Proposed Solution

Add a `session_strategy/1` callback to workflow phase modules that returns session lifecycle + configuration hints per phase. Wire this through the existing `SetupWorker`, `AiQueryWorker`, and `Setup` modules so session options are resolved from the workflow phase module rather than hardcoded.

## Technical Approach

### Step 1: Add `session_strategy/1` to `ChoreTaskPhases`

**File:** `lib/destila/workflows/chore_task_phases.ex`

Add a new function that returns the session strategy for each phase:

```elixir
@doc """
Returns the session strategy for a given phase.

Possible return values:
  - `:resume` — continue the existing session (default behavior)
  - `{:resume, claude_opts}` — continue with additional ClaudeCode options
  - `:new` — start a fresh session with default options
  - `{:new, claude_opts}` — start a fresh session with specific options
"""
def session_strategy(_phase), do: :resume
```

For `ChoreTaskPhases`, all phases return `:resume` — preserving current behavior exactly.

### Step 2: Add dispatch in `Destila.Workflows`

**File:** `lib/destila/workflows.ex`

Add a dispatcher function that routes to the correct phase module based on `workflow_type`, following the existing pattern used by `phase_name/2`:

```elixir
def session_strategy(:prompt_chore_task, phase),
  do: Destila.Workflows.ChoreTaskPhases.session_strategy(phase)

# Default for non-AI workflow types
def session_strategy(_type, _phase), do: :resume
```

### Step 3: Add `merge_phase_opts/2` to `Destila.AI.Session`

**File:** `lib/destila/ai/session.ex`

Add a helper function that merges phase-provided options with session defaults. The merge rules are:

- **`mcp_servers`**: Map.merge — phase servers are added alongside the Destila MCP server (which is always injected via `put_new` in `init/1`)
- **`allowed_tools`**: If the phase provides this key, it replaces the default entirely (callers wanting unrestricted access won't pass `allowed_tools` at all, so `put_new` in `init/1` will not apply the default)
- **All other options**: Standard `Keyword.merge` (phase opts take precedence)

```elixir
@doc """
Merges phase-provided ClaudeCode options with base session options.
MCP servers are map-merged; all other options use standard keyword merge.
"""
def merge_phase_opts(base_opts, phase_opts) do
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
```

Note: `init/1` already uses `Keyword.put_new` for both `allowed_tools` and `mcp_servers`. If a phase passes these keys, `put_new` won't override them. If a phase uses `dangerously_skip_permissions: true` and doesn't pass `allowed_tools`, `put_new` will apply the default — which is fine because `dangerously_skip_permissions` bypasses tool restrictions regardless. However, to be clean, phases wanting unrestricted access should explicitly pass `allowed_tools: []` or omit it and let the default apply harmlessly.

### Step 4: Update `SetupWorker.build_session_opts/1`

**File:** `lib/destila/workers/setup_worker.ex`

Update `build_session_opts/1` to resolve the session strategy from the workflow phase module and incorporate phase options:

```elixir
defp build_session_opts(workflow_session) do
  strategy = Destila.Workflows.session_strategy(
    workflow_session.workflow_type,
    workflow_session.steps_completed
  )

  {action, phase_opts} = normalize_strategy(strategy)

  opts = [timeout_ms: :timer.minutes(15)]

  opts =
    case action do
      :resume ->
        if workflow_session.ai_session_id do
          Keyword.put(opts, :resume, workflow_session.ai_session_id)
        else
          opts
        end

      :new ->
        # Don't pass :resume even if ai_session_id exists
        opts
    end

  opts =
    if workflow_session.worktree_path do
      Keyword.put(opts, :cwd, workflow_session.worktree_path)
    else
      opts
    end

  Destila.AI.Session.merge_phase_opts(opts, phase_opts)
end

defp normalize_strategy(:resume), do: {:resume, []}
defp normalize_strategy(:new), do: {:new, []}
defp normalize_strategy({action, opts}) when action in [:resume, :new], do: {action, opts}
```

When `action` is `:new`, the existing session (if any) must be stopped first. Update `start_ai_session_and_trigger/1` to handle this:

```elixir
defp start_ai_session_and_trigger(workflow_session) do
  broadcast_step(workflow_session.id, "ai_session", "in_progress", "Starting AI session...")

  workflow_session = WorkflowSessions.get_workflow_session!(workflow_session.id)
  {action, _} = normalize_strategy(
    Destila.Workflows.session_strategy(
      workflow_session.workflow_type,
      workflow_session.steps_completed
    )
  )

  # Stop existing session if strategy requires a new one
  if action == :new do
    Destila.AI.Session.stop_for_workflow_session(workflow_session.id)
  end

  session_opts = build_session_opts(workflow_session)
  # ... rest unchanged
end
```

### Step 5: Update `AiQueryWorker.build_session_opts/1`

**File:** `lib/destila/workers/ai_query_worker.ex`

Apply the same pattern. The worker receives `phase` in job args, so use that:

```elixir
defp build_session_opts(ws, phase) do
  strategy = Destila.Workflows.session_strategy(ws.workflow_type, phase)
  {action, phase_opts} = normalize_strategy(strategy)

  opts = []

  opts =
    case action do
      :resume ->
        if ws.ai_session_id,
          do: Keyword.put(opts, :resume, ws.ai_session_id),
          else: opts

      :new ->
        opts
    end

  opts =
    if ws.worktree_path,
      do: Keyword.put(opts, :cwd, ws.worktree_path),
      else: opts

  Destila.AI.Session.merge_phase_opts(opts, phase_opts)
end

defp normalize_strategy(:resume), do: {:resume, []}
defp normalize_strategy(:new), do: {:new, []}
defp normalize_strategy({action, opts}) when action in [:resume, :new], do: {action, opts}
```

Update `perform/1` to handle `:new` strategy by stopping the existing session before creating a new one:

```elixir
def perform(%Oban.Job{args: %{...} = args}) do
  ws = WorkflowSessions.get_workflow_session!(workflow_session_id)
  strategy = Destila.Workflows.session_strategy(ws.workflow_type, phase)
  {action, _} = normalize_strategy(strategy)

  if action == :new do
    Destila.AI.Session.stop_for_workflow_session(workflow_session_id)
  end

  session_opts = build_session_opts(ws, phase)
  # ... rest unchanged, using session_opts
end
```

Also update `handle_skip_phase/2` to use the dispatcher instead of hardcoding `ChoreTaskPhases`:

```elixir
defp handle_skip_phase(workflow_session_id, current_phase) do
  next_phase = current_phase + 1

  WorkflowSessions.update_workflow_session(workflow_session_id, %{
    steps_completed: next_phase,
    phase_status: :generating
  })

  workflow_session = WorkflowSessions.get_workflow_session!(workflow_session_id)

  # Dispatch through Workflows module instead of hardcoding ChoreTaskPhases
  phases_module = Destila.Workflows.phases_module(workflow_session.workflow_type)
  phase_prompt = phases_module.system_prompt(next_phase, workflow_session)

  # ... enqueue next job
end
```

### Step 6: Update `Destila.Setup.trigger_phase1/1`

**File:** `lib/destila/setup.ex`

Replace the hardcoded `ChoreTaskPhases` reference with dispatcher:

```elixir
defp trigger_phase1(workflow_session) do
  phase = 1

  messages =
    Messages.list_messages(workflow_session.id)
    |> Enum.filter(&(&1.phase > 0))

  phases_module = Destila.Workflows.phases_module(workflow_session.workflow_type)
  system_prompt = phases_module.system_prompt(phase, workflow_session)
  context = phases_module.build_conversation_context(messages)
  query = system_prompt <> "\n\n" <> context

  # ... rest unchanged
end
```

### Step 7: Add `phases_module/1` to `Destila.Workflows`

**File:** `lib/destila/workflows.ex`

Add a dispatcher that maps workflow_type to the phases module:

```elixir
@doc """
Returns the phases module for a given workflow type.
"""
def phases_module(:prompt_chore_task), do: Destila.Workflows.ChoreTaskPhases
def phases_module(_type), do: nil
```

This is used by `Setup.trigger_phase1` and `AiQueryWorker.handle_skip_phase` to resolve system prompts and conversation context builders without hardcoding the module.

### Step 8: Extract `normalize_strategy/1` to shared location

Both `SetupWorker` and `AiQueryWorker` need `normalize_strategy/1`. Rather than duplicating it, add it to `Destila.Workflows`:

```elixir
@doc """
Normalizes a session strategy to `{action, opts}` tuple form.
"""
def normalize_strategy(:resume), do: {:resume, []}
def normalize_strategy(:new), do: {:new, []}
def normalize_strategy({action, opts}) when action in [:resume, :new], do: {action, opts}
```

## Acceptance Criteria

- [x] `ChoreTaskPhases.session_strategy/1` exists and returns `:resume` for all phases
- [x] `Destila.Workflows.session_strategy/2` dispatches to the correct phases module
- [x] `Destila.Workflows.phases_module/1` returns the correct module for each workflow type
- [x] `Destila.Workflows.normalize_strategy/1` normalizes all strategy forms
- [x] `Session.merge_phase_opts/2` correctly merges MCP servers and other options
- [x] `SetupWorker.build_session_opts/1` resolves strategy from the workflow phase module
- [x] `AiQueryWorker.build_session_opts/2` resolves strategy from the workflow phase module (now takes `phase` arg)
- [x] `AiQueryWorker.handle_skip_phase/2` uses `Workflows.phases_module/1` instead of hardcoded `ChoreTaskPhases`
- [x] `Setup.trigger_phase1/1` uses `Workflows.phases_module/1` instead of hardcoded `ChoreTaskPhases`
- [x] Existing `ChoreTaskPhases` workflow behavior is unchanged (all phases resume, same tools, same MCP)
- [x] When strategy is `:new`, existing session is stopped before starting a fresh one
- [x] Destila MCP server (`"destila" => Destila.AI.Tools`) is always present regardless of phase options (guaranteed by `put_new` in `Session.init/1`)

## SDK Options Reference

From `ClaudeCode.Options` (v0.32.2), key options for future workflow phases:

| Option | Type | Purpose |
|--------|------|---------|
| `dangerously_skip_permissions` | boolean | Bypass all permission checks |
| `mcp_servers` | map | MCP server configs (merged with Destila MCP) |
| `strict_mcp_config` | boolean | Only use explicit MCP servers, ignore global |
| `setting_sources` | list | Which settings to load (`["project"]` for project-only) |
| `allowed_tools` | list | Tool restrictions (omit for unrestricted) |
| `cwd` | string | Working directory (already wired) |
| `resume` | string | Session ID to resume (already wired) |

## Dependencies & Risks

**Low risk.** This is additive wiring with no behavioral change for the existing workflow.

- `ChoreTaskPhases` returns `:resume` for all phases — identical to current behavior
- `Session.init/1` already supports override via `put_new` semantics — no changes needed there
- `normalize_strategy/1` is trivial pattern matching
- `merge_phase_opts/2` only applies when phase opts are non-empty

**One subtle risk:** `AiQueryWorker` currently doesn't pass `timeout_ms`, so recreated sessions get the 5-min default instead of SetupWorker's 15-min. This is a pre-existing inconsistency, not introduced by this change, but worth noting for future work.

## Files to Modify

| File | Change |
|------|--------|
| `lib/destila/workflows/chore_task_phases.ex` | Add `session_strategy/1` |
| `lib/destila/workflows.ex` | Add `session_strategy/2`, `phases_module/1`, `normalize_strategy/1` |
| `lib/destila/ai/session.ex` | Add `merge_phase_opts/2` |
| `lib/destila/workers/setup_worker.ex` | Update `build_session_opts/1`, `start_ai_session_and_trigger/1` |
| `lib/destila/workers/ai_query_worker.ex` | Update `build_session_opts` (add phase arg), `perform/1`, `handle_skip_phase/2` |
| `lib/destila/setup.ex` | Replace hardcoded `ChoreTaskPhases` with `Workflows.phases_module/1` |

## References

### Internal

- `lib/destila/ai/session.ex:10-18` — Current default allowed tools and MCP server
- `lib/destila/ai/session.ex:131-152` — `init/1` with `put_new` semantics
- `lib/destila/workers/setup_worker.ex:117-132` — Current `build_session_opts/1`
- `lib/destila/workers/ai_query_worker.ex:80-91` — Current `build_session_opts/1`
- `lib/destila/workers/ai_query_worker.ex:93-111` — `handle_skip_phase/2` hardcoded to `ChoreTaskPhases`
- `lib/destila/setup.ex:69-88` — `trigger_phase1/1` hardcoded to `ChoreTaskPhases`
- `lib/destila/workflows.ex:80-81` — Existing dispatch pattern for `phase_name/2`
- `deps/claude_code/lib/claude_code/options.ex:600-611` — `dangerously_skip_permissions` option
- `deps/claude_code/lib/claude_code/options.ex:557-566` — `mcp_servers` and `strict_mcp_config` options

### Prior Plans

- `docs/plans/2026-03-20-feat-chore-task-workflow-plan.md` — Original AI-driven phase system design
- `docs/plans/2026-03-22-feat-phase-zero-setup-worktree-plan.md` — Phase 0 background job architecture
