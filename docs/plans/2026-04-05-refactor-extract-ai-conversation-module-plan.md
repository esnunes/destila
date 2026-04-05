---
title: "refactor: Extract duplicated AI conversation logic into Destila.AI.Conversation"
type: refactor
date: 2026-04-05
---

# refactor: Extract duplicated AI conversation logic into Destila.AI.Conversation

## Overview

Both `BrainstormIdeaWorkflow` and `ImplementGeneralPromptWorkflow` contain near-identical AI conversation mechanics: starting phases, handling user messages, processing AI results/errors, managing session strategy, and enqueuing workers. Extract all of this into a new `Destila.AI.Conversation` module that the Engine calls directly. Workflow modules become purely declarative — they define phases and metadata, plus an optional `handle_response/3` callback for workflow-specific response processing.

User-facing behavior is unchanged. No Gherkin changes needed.

## Current state

Both workflow modules implement the same imperative functions:

- **`phase_start_action/2`** — look up phase, ensure AI session exists, execute system prompt, enqueue worker. `ImplementGeneralPromptWorkflow` additionally calls `handle_session_strategy/2` before `ensure_ai_session`.
- **`phase_update_action/3` (4 clauses each)** — user message, AI result, AI error, catch-all. The AI result clause is identical except `BrainstormIdeaWorkflow` calls `save_phase_metadata/3` between saving the message and deciding the next action.
- **`ensure_ai_session/1`** — identical in both modules.
- **`enqueue_ai_worker/3`** — identical in both modules.

Additionally:
- `ImplementGeneralPromptWorkflow` has `handle_session_strategy/2` (`:new` stops ClaudeSession and creates fresh AI session; anything else is a no-op).
- `BrainstormIdeaWorkflow` has `build_conversation_context/1` (dead code — not called anywhere).
- The `Workflow` behaviour defines `phase_start_action` and `phase_update_action` callbacks.
- The `Workflows` dispatcher has `phase_start_action/1` and `phase_update_action/2` delegation functions.
- The `Engine` calls these dispatcher functions, which route to workflow modules.
- The `Engine.handle_retry/1` also duplicates session strategy logic (stop ClaudeSession, optionally create fresh AI session).

## Solution

### New module: `Destila.AI.Conversation`

A single module that owns all AI conversation mechanics. The Engine calls it directly for phase starts and updates.

```
Engine
  |
  |--- calls ---> AI.Conversation.phase_start(ws)
  |               AI.Conversation.phase_update(ws, params)
  |
  |               AI.Conversation internally:
  |                 - Reads Phase struct from workflow module
  |                 - Handles session strategy
  |                 - Ensures AI session exists
  |                 - Saves messages, enqueues workers
  |                 - Calls optional workflow.handle_response/3
  |                 - Returns status atom to Engine
  |
Workflow modules (declarative only):
  - phases/0, label/0, icon/0, etc.
  - handle_response/3 (optional callback)
```

### Key design decisions

1. **`AI.Conversation` reads phase definitions itself** — it calls `Workflows.phases(ws.workflow_type)` and `Enum.at(phases, phase_number - 1)` to get the `%Phase{}` struct. Workflow modules don't need to be called for this.

2. **Session strategy lives in `AI.Conversation.phase_start/1`** — before ensuring the AI session, it checks `phase.session_strategy`. For `:new`, it stops the ClaudeSession and creates a fresh AI session. For `:resume` (default), it's a no-op. This consolidates `ImplementGeneralPromptWorkflow.handle_session_strategy/2` and `Engine.handle_retry/1`'s strategy logic.

3. **Optional `handle_response/3` callback** — after saving the AI message and before deciding the status, `AI.Conversation` calls `workflow_module.handle_response(ws, phase_number, response_text)`. The `Workflow` `__using__` macro provides a default no-op implementation. Only `BrainstormIdeaWorkflow` overrides it (to save generated prompt metadata).

4. **Engine.handle_retry/1 reuses `AI.Conversation`** — the retry logic currently duplicates session strategy handling. After this refactoring, `handle_retry/1` calls `AI.Conversation.handle_session_strategy/2` for the strategy part, then calls `AI.Conversation.phase_start/1` for the restart.

## Implementation steps

### Step 1: Add `handle_response/3` callback to `Workflow` behaviour

**File: `lib/destila/workflows/workflow.ex`**

Add the callback and a default no-op implementation:

```elixir
@doc """
Optional hook called after saving an AI response message.

Allows workflows to intercept responses for workflow-specific purposes
(e.g. saving generated prompt metadata). Default implementation is a no-op.
"""
@callback handle_response(
            workflow_session :: map(),
            phase_number :: integer(),
            response_text :: String.t()
          ) :: :ok

# In the __using__ macro, add default:
def handle_response(_workflow_session, _phase_number, _response_text), do: :ok

defoverridable total_phases: 0, phase_name: 1, phase_columns: 0, handle_response: 3
```

### Step 2: Extract `save_phase_metadata/3` into `BrainstormIdeaWorkflow.handle_response/3`

**File: `lib/destila/workflows/brainstorm_idea_workflow.ex`**

Rename the existing `save_phase_metadata/3` logic into the new callback. Change from `defp` to `def` and rename:

```elixir
@impl true
def handle_response(ws, phase_number, response_text) do
  case Enum.at(phases(), phase_number - 1) do
    %Phase{message_type: :generated_prompt} ->
      phase_name = phase_name(phase_number)

      Destila.Workflows.upsert_metadata(
        ws.id,
        phase_name,
        "prompt_generated",
        %{"text" => String.trim(response_text)},
        exported: true
      )

      :ok

    _ ->
      :ok
  end
end
```

### Step 3: Create `Destila.AI.Conversation` module

**New file: `lib/destila/ai/conversation.ex`**

```elixir
defmodule Destila.AI.Conversation do
  @moduledoc """
  Handles all AI conversation mechanics — phase starts, user messages,
  AI results, and AI errors.

  The Engine calls this module directly instead of delegating to workflow
  modules. Workflow modules remain purely declarative.
  """

  alias Destila.{AI, Workflows}

  @doc """
  Starts a phase by reading the system prompt, handling session strategy,
  ensuring an AI session exists, and enqueuing the AI worker.

  Returns `:processing` or `:awaiting_input`.
  """
  def phase_start(ws) do
    phase_number = ws.current_phase

    case get_phase(ws, phase_number) do
      %{system_prompt: prompt_fn} when not is_nil(prompt_fn) ->
        handle_session_strategy(ws, phase_number)
        ensure_ai_session(ws)
        query = prompt_fn.(ws)
        enqueue_ai_worker(ws, phase_number, query)
        :processing

      _ ->
        :awaiting_input
    end
  end

  @doc """
  Processes a phase update (user message, AI result, AI error, or unknown).

  Returns `:processing`, `:awaiting_input`, `:phase_complete`, or `:suggest_phase_complete`.
  """
  def phase_update(ws, %{message: message}) do
    phase_number = ws.current_phase
    ai_session = AI.get_ai_session_for_workflow(ws.id)

    if ai_session do
      AI.create_message(ai_session.id, %{
        role: :user,
        content: message,
        phase: phase_number
      })

      enqueue_ai_worker(ws, phase_number, message)
      :processing
    else
      :awaiting_input
    end
  end

  def phase_update(ws, %{ai_result: result}) do
    phase_number = ws.current_phase
    ai_session = AI.get_ai_session_for_workflow(ws.id)

    if ai_session do
      response_text = AI.response_text(result)
      session_action = AI.extract_session_action(result)

      content =
        case session_action do
          %{message: msg} when is_binary(msg) and msg != "" -> msg
          _ -> response_text
        end

      AI.create_message(ai_session.id, %{
        role: :system,
        content: content,
        raw_response: result,
        phase: phase_number
      })

      if result[:session_id] do
        AI.update_ai_session(ai_session, %{claude_session_id: result[:session_id]})
      end

      # Call optional workflow hook
      workflow_module = Workflows.workflow_module(ws.workflow_type)
      workflow_module.handle_response(ws, phase_number, response_text)

      case session_action do
        %{action: "phase_complete"} -> :phase_complete
        %{action: "suggest_phase_complete"} -> :suggest_phase_complete
        _ -> :awaiting_input
      end
    else
      :awaiting_input
    end
  end

  def phase_update(ws, %{ai_error: _reason}) do
    phase_number = ws.current_phase
    ai_session = AI.get_ai_session_for_workflow(ws.id)

    if ai_session do
      AI.create_message(ai_session.id, %{
        role: :system,
        content: "Something went wrong. Please try sending your message again.",
        phase: phase_number
      })
    end

    :awaiting_input
  end

  def phase_update(_ws, _params), do: :awaiting_input

  @doc """
  Handles session strategy for a given phase.

  For `:new` — stops the existing ClaudeSession and creates a fresh AI session.
  For `:resume` — no-op.

  This is also used by `Engine.handle_retry/1` to apply the phase's strategy
  before restarting.
  """
  def handle_session_strategy(ws, phase_number) do
    case get_phase(ws, phase_number) do
      %{session_strategy: :new} ->
        AI.ClaudeSession.stop_for_workflow_session(ws.id)

        metadata = Workflows.get_metadata(ws.id)
        worktree_path = get_in(metadata, ["worktree", "worktree_path"])

        AI.create_ai_session(%{
          workflow_session_id: ws.id,
          worktree_path: worktree_path
        })

      _ ->
        :ok
    end
  end

  # --- Private ---

  defp get_phase(ws, phase_number) do
    Enum.at(Workflows.phases(ws.workflow_type), phase_number - 1)
  end

  defp ensure_ai_session(ws) do
    case AI.get_ai_session_for_workflow(ws.id) do
      nil ->
        metadata = Workflows.get_metadata(ws.id)
        worktree_path = get_in(metadata, ["worktree", "worktree_path"])

        {:ok, session} =
          AI.get_or_create_ai_session(ws.id, %{worktree_path: worktree_path})

        session

      session ->
        session
    end
  end

  defp enqueue_ai_worker(ws, phase, query) do
    %{"workflow_session_id" => ws.id, "phase" => phase, "query" => query}
    |> Destila.Workers.AiQueryWorker.new()
    |> Oban.insert()
  end
end
```

### Step 4: Update `Engine` to call `AI.Conversation` directly

**File: `lib/destila/executions/engine.ex`**

Add alias:
```elixir
alias Destila.{Executions, Workflows}
# becomes:
alias Destila.{AI, Executions, Workflows}
```

**`start_session/1`** — replace `Workflows.phase_start_action(ws)` with `AI.Conversation.phase_start(ws)`:

```elixir
def start_session(ws) do
  phase = ws.current_phase
  {:ok, pe} = Executions.ensure_phase_execution(ws, phase)
  status = AI.Conversation.phase_start(ws)
  # ... rest unchanged
end
```

**`transition_to_phase/2`** — same replacement:

```elixir
defp transition_to_phase(ws, next_phase) do
  {:ok, pe} = Executions.ensure_phase_execution(ws, next_phase)
  {:ok, ws} = Workflows.update_workflow_session(ws, %{current_phase: next_phase})
  status = AI.Conversation.phase_start(ws)
  # ... rest unchanged
end
```

**`phase_update/3` (non-setup clause)** — replace `Workflows.phase_update_action(...)` with `AI.Conversation.phase_update(...)`:

```elixir
def phase_update(workflow_session_id, phase, params) do
  ws = Workflows.get_workflow_session!(workflow_session_id)

  case AI.Conversation.phase_update(%{ws | current_phase: phase}, params) do
    # ... same case branches, unchanged
  end
end
```

**`handle_retry/1`** — replace the inline session strategy logic with `AI.Conversation.handle_session_strategy/2`, and replace `Workflows.phase_start_action(ws)` with `AI.Conversation.phase_start(ws)`:

Before:
```elixir
defp handle_retry(ws) do
  phase = ws.current_phase
  {strategy, _opts} = Workflows.session_strategy(ws.workflow_type, phase)

  case strategy do
    :new ->
      Destila.AI.ClaudeSession.stop_for_workflow_session(ws.id)
      metadata = Workflows.get_metadata(ws.id)
      worktree_path = get_in(metadata, ["worktree", "worktree_path"])
      Destila.AI.create_ai_session(%{workflow_session_id: ws.id, worktree_path: worktree_path})

    :resume ->
      Destila.AI.ClaudeSession.stop_for_workflow_session(ws.id)
  end

  ws = Workflows.get_workflow_session!(ws.id)
  status = Workflows.phase_start_action(ws)
  # ...
end
```

After:
```elixir
defp handle_retry(ws) do
  phase = ws.current_phase

  # Stop the running ClaudeSession for all strategies
  AI.ClaudeSession.stop_for_workflow_session(ws.id)

  # Apply the phase's session strategy (create fresh AI session if :new)
  AI.Conversation.handle_session_strategy(ws, phase)

  ws = Workflows.get_workflow_session!(ws.id)
  status = AI.Conversation.phase_start(ws)
  # ... rest unchanged
end
```

Note: The current `handle_retry/1` always stops the ClaudeSession regardless of strategy. `AI.Conversation.handle_session_strategy/2` only stops it for `:new`. To preserve the current behavior, the Engine should stop the ClaudeSession explicitly before calling `handle_session_strategy`, since retry always needs to stop the running session even for `:resume`.

### Step 5: Remove imperative functions from workflow modules

**File: `lib/destila/workflows/brainstorm_idea_workflow.ex`**

Remove these functions:
- `phase_start_action/2` (lines 49–60)
- All four `phase_update_action/3` clauses (lines 62–130)
- `save_phase_metadata/3` (lines 132–148) — replaced by `handle_response/3`
- `ensure_ai_session/1` (lines 150–164)
- `enqueue_ai_worker/3` (lines 166–170)
- `build_conversation_context/1` (lines 331–349) — dead code

Keep:
- `phases/0`, `creation_config/0`, `default_title/0`, `label/0`, `description/0`, `icon/0`, `icon_class/0`, `completion_message/0`
- `handle_response/3` (new, from step 2)
- All system prompt functions (`task_description_prompt/1`, etc.)
- The `@tool_instructions` module attribute

**File: `lib/destila/workflows/implement_general_prompt_workflow.ex`**

Remove these functions:
- `phase_start_action/2` (lines 116–128)
- All four `phase_update_action/3` clauses (lines 130–195)
- `handle_session_strategy/2` (lines 197–209)
- `ensure_ai_session/1` (lines 211–225)
- `enqueue_ai_worker/3` (lines 227–231)

Keep:
- `phases/0`, `creation_config/0`, `default_title/0`, `label/0`, `description/0`, `icon/0`, `icon_class/0`, `completion_message/0`
- All system prompt functions (`plan_prompt/1`, etc.)
- The `@non_interactive_tool_instructions` and `@implementation_tools` module attributes

`ImplementGeneralPromptWorkflow` does not need `handle_response/3` — it uses the default no-op.

### Step 6: Update `Workflow` behaviour

**File: `lib/destila/workflows/workflow.ex`**

Remove callbacks:
- `@callback phase_start_action/2`
- `@callback phase_update_action/3`

Add callback:
- `@callback handle_response/3` (with `@optional_callbacks [handle_response: 3]` or a default in `__using__`)

The default implementation in `__using__`:
```elixir
def handle_response(_workflow_session, _phase_number, _response_text), do: :ok

defoverridable total_phases: 0, phase_name: 1, phase_columns: 0, handle_response: 3
```

### Step 7: Remove dispatcher functions from `Workflows` context

**File: `lib/destila/workflows.ex`**

Remove:
- `phase_start_action/1` (lines 66–71)
- `phase_update_action/2` (lines 73–79)
- `session_strategy/2` (lines 59–64)
- `normalize_strategy/1` (lines 81–83)

`session_strategy/2` and `normalize_strategy/1` are no longer needed because `AI.Conversation` reads the strategy directly from the `%Phase{}` struct.

Keep `workflow_module/1` — it's still used by `AI.Conversation` to look up the module for `handle_response/3`.

### Step 8: Verify and run tests

Run `mix precommit` to ensure:
- Compilation succeeds
- All existing tests pass without modification
- No unused function warnings

**Expected test behavior:**
- `EngineTest` — all tests should pass. They test through `Engine.phase_update/3` which now calls `AI.Conversation` instead of going through the workflow dispatcher. The AI session setup and assertions remain the same.
- `WorkflowTest` — tests for `total_phases/0`, `phase_name/1`, `phase_columns/0`, `creation_config/0`, and `session_strategy` on Phase structs all pass (they test declarative functions, not the removed imperative ones).
- `ImplementGeneralPromptWorkflowLiveTest` — two tests call `Workflows.session_strategy/2` directly (lines 341 and 348). These must be updated to read the `session_strategy` field from the `%Phase{}` struct directly, since the dispatcher function is being removed. E.g.: `Enum.at(ImplementGeneralPromptWorkflow.phases(), 2).session_strategy == :new`.
- Other LiveView integration tests — unchanged behavior, should pass.

## Files to modify

1. **`lib/destila/ai/conversation.ex`** — NEW: central AI conversation module
2. **`lib/destila/executions/engine.ex`** — call `AI.Conversation` instead of `Workflows` dispatcher
3. **`lib/destila/workflows/workflow.ex`** — remove `phase_start_action`/`phase_update_action` callbacks, add `handle_response/3`
4. **`lib/destila/workflows.ex`** — remove `phase_start_action/1`, `phase_update_action/2`, `session_strategy/2`, `normalize_strategy/1`
5. **`lib/destila/workflows/brainstorm_idea_workflow.ex`** — remove all imperative functions, add `handle_response/3`, remove dead `build_conversation_context/1`
6. **`lib/destila/workflows/implement_general_prompt_workflow.ex`** — remove all imperative functions

## Files to update (tests)

7. **`test/destila_web/live/implement_general_prompt_workflow_live_test.exs`** — update two tests that call `Workflows.session_strategy/2` to read `Phase.session_strategy` directly from the struct

## Files confirmed unchanged

1. **Feature files** — pure internal refactoring, no behavior change
2. **`lib/destila/ai.ex`** — AI context functions are called by `AI.Conversation`, not changed
3. **`lib/destila/ai/claude_session.ex`** — reads phase structs directly via `Workflows.phases/1`, does not use `Workflows.session_strategy/2`
4. **`lib/destila/workflows/phase.ex`** — Phase struct unchanged
5. **Database schemas and migrations** — no changes
6. **LiveView files** — no UI changes
7. **`test/destila/executions/engine_test.exs`** — tests through Engine, unaffected
8. **`test/destila/workflow_test.exs`** — tests declarative functions only (phase struct fields, not dispatcher functions)

## Risks and mitigations

1. **`handle_retry/1` behavior difference** — currently the Engine always stops ClaudeSession for both `:new` and `:resume` strategies. `AI.Conversation.handle_session_strategy/2` only stops it for `:new`. The Engine must continue stopping the session explicitly for all retries before calling `handle_session_strategy`. This is handled in step 4.

2. **`phase_update` receives `ws` with overridden `current_phase`** — the Engine currently does `%{ws | current_phase: phase}` before passing to the workflow. `AI.Conversation.phase_update/2` must use `ws.current_phase` (which will be the overridden value). This works naturally since we pass the same modified struct.

3. **`Workflows.session_strategy/2` callers** — three callers exist: `Engine.handle_retry/1` (updated in step 4), `ImplementGeneralPromptWorkflowLiveTest` (two tests updated in step 8), and `ClaudeSession.session_opts_for_workflow/3` (reads phase structs directly via `Workflows.phases/1`, does NOT call `session_strategy/2` — safe to remove).
