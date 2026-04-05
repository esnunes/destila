---
title: "refactor: Inline AI conversation into workflow runner, remove phase-module indirection"
type: refactor
date: 2026-04-04
---

# refactor: Inline AI conversation into workflow runner, remove phase-module indirection

## Overview

Remove the `{module, opts}` phase indirection from the workflow framework. Every phase in both workflows uses `AiConversationPhase` — the extensibility is unused complexity. Replace with `%Workflow.Phase{}` structs, move the chat UI to a function component, absorb event handling into `WorkflowRunnerLive`, and delete the `AiConversationPhase` LiveComponent.

User-facing behavior is unchanged. This is a pure internal refactoring.

## Current state

- `Destila.Workflow` behaviour defines `phases/0` returning `[{module, keyword()}]` tuples
- Every phase across both workflows sets `module` to `DestilaWeb.Phases.AiConversationPhase`
- `AiConversationPhase` is a LiveComponent that:
  - Owns chat rendering (message list, streaming, phase groups, structured inputs)
  - Handles 9 events (`send_text`, `select_single`, `select_multi`, `answer_question`, `confirm_multi_answer`, `submit_all_answers`, `retry_phase`, `cancel_phase`)
  - Manages `question_answers` state for multi-question forms
  - Delegates to `Destila.Executions.Engine` for phase updates
- `WorkflowRunnerLive` mounts the phase's `module` via `<.live_component>` and passes `opts` as-is
- Both workflow modules (`BrainstormIdeaWorkflow`, `ImplementGeneralPromptWorkflow`) access phase opts via `Enum.at(phases(), n - 1)` to extract `system_prompt`, `allowed_tools`, `message_type`, etc.
- `ClaudeSession.session_opts_for_workflow/3` pattern-matches `{_mod, opts}` to extract `allowed_tools`

## Solution

### Architecture

```
WorkflowRunnerLive (event handler + orchestrator)
        |
        |--- renders ---> ChatComponents (function components, stateless)
        |                     chat_phase/1 — full phase container
        |                     (reuses existing chat_message/1, text_input/1, etc.)
        |
        |--- delegates --> Destila.Executions.Engine (phase transitions)
        |
Workflow.phases/0 returns [%Phase{}, ...]
```

### Key design decisions

1. **`%Destila.Workflow.Phase{}` struct** — replaces `{module, keyword()}` tuples. Fields: `name`, `system_prompt`, `skippable` (default `false`), `final` (default `false`), `non_interactive` (default `false`), `allowed_tools` (default `[]`), plus any workflow-specific fields like `message_type`. Uses `@enforce_keys [:name, :system_prompt]` for compile-time validation.

2. **Function component in `ChatComponents`** — a new `chat_phase/1` function component replaces the LiveComponent's `render/1`. It receives all data as assigns (messages, phase config, phase status, streaming chunks, question_answers, phase_number, workflow_session) and emits events to the parent LiveView. No internal state — `question_answers` moves to `WorkflowRunnerLive`.

3. **`WorkflowRunnerLive` handles all chat events** — the 9 event handlers from `AiConversationPhase` move to the runner. The runner already owns `workflow_session`, `streaming_chunks`, and `metadata`. It gains `question_answers` as a new assign.

4. **Workflow modules return `%Phase{}` structs** — `phase_start_action/2` and `phase_update_action/3` access struct fields directly (e.g. `phase.system_prompt`) instead of `Keyword.get(opts, :system_prompt)`.

5. **`Workflow` behaviour macro** — the `__using__` macro updates `phase_name/1` and `phase_columns/0` to pattern-match `%Phase{name: name}` instead of `{_mod, opts}`.

6. **Delete `AiConversationPhase`** — the file `lib/destila_web/live/phases/ai_conversation_phase.ex` is removed entirely.

## Implementation steps

### Step 1: Define `Destila.Workflow.Phase` struct

**New file: `lib/destila/workflow/phase.ex`**

```elixir
defmodule Destila.Workflow.Phase do
  @enforce_keys [:name, :system_prompt]
  defstruct [
    :name,
    :system_prompt,
    :message_type,
    skippable: false,
    final: false,
    non_interactive: false,
    allowed_tools: []
  ]
end
```

Fields map 1:1 to the current keyword opts. `message_type` is used by `BrainstormIdeaWorkflow` for the prompt generation phase.

### Step 2: Update `Destila.Workflow` behaviour and macro

**File: `lib/destila/workflow.ex`**

- Change the `@type phase_definition` from `{module(), keyword()}` to `%Destila.Workflow.Phase{}`
- Update the `@callback phases()` return type to `[%Destila.Workflow.Phase{}]`
- Update `phase_name/1` in the `__using__` macro:

  Before:
  ```elixir
  def phase_name(phase) when is_integer(phase) do
    case Enum.at(phases(), phase - 1) do
      {_mod, opts} -> Keyword.get(opts, :name)
      nil -> nil
    end
  end
  ```

  After:
  ```elixir
  def phase_name(phase) when is_integer(phase) do
    case Enum.at(phases(), phase - 1) do
      %Destila.Workflow.Phase{name: name} -> name
      nil -> nil
    end
  end
  ```

- Same pattern for `phase_columns/0` (no functional change, just struct access).

### Step 3: Update both workflow modules to return `%Phase{}` structs

**File: `lib/destila/workflows/brainstorm_idea_workflow.ex`**

Replace tuple syntax with struct syntax:

Before:
```elixir
def phases do
  [
    {DestilaWeb.Phases.AiConversationPhase,
     name: "Task Description", system_prompt: &task_description_prompt/1},
    ...
  ]
end
```

After:
```elixir
alias Destila.Workflow.Phase

def phases do
  [
    %Phase{name: "Task Description", system_prompt: &task_description_prompt/1},
    %Phase{name: "Gherkin Review", system_prompt: &gherkin_review_prompt/1, skippable: true},
    %Phase{name: "Technical Concerns", system_prompt: &technical_concerns_prompt/1},
    %Phase{
      name: "Prompt Generation",
      system_prompt: &prompt_generation_prompt/1,
      final: true,
      message_type: :generated_prompt
    }
  ]
end
```

Update `phase_start_action/2` to pattern-match on `%Phase{}`:

Before:
```elixir
def phase_start_action(ws, phase_number) do
  case Enum.at(phases(), phase_number - 1) do
    {_mod, opts} ->
      case Keyword.get(opts, :system_prompt) do
        ...
      end
    nil -> :awaiting_input
  end
end
```

After:
```elixir
def phase_start_action(ws, phase_number) do
  case Enum.at(phases(), phase_number - 1) do
    %Phase{system_prompt: prompt_fn} when not is_nil(prompt_fn) ->
      ensure_ai_session(ws)
      query = prompt_fn.(ws)
      enqueue_ai_worker(ws, phase_number, query)
      :processing
    _ ->
      :awaiting_input
  end
end
```

Update `save_phase_metadata/3` similarly — access `phase.message_type` instead of `Keyword.get(opts, :message_type)`.

**File: `lib/destila/workflows/implement_general_prompt_workflow.ex`**

Same pattern. Replace all `{DestilaWeb.Phases.AiConversationPhase, ...}` tuples with `%Phase{}` structs.

Update `phase_start_action/2` — same struct pattern matching as Brainstorm. Also update `handle_session_strategy/2` call (unchanged logic, just struct access).

### Step 4: Update `ClaudeSession.session_opts_for_workflow/3`

**File: `lib/destila/ai/claude_session.ex`**

The function currently pattern-matches `{_mod, opts}` to extract `allowed_tools`:

Before:
```elixir
phase_def_opts =
  case Enum.at(Destila.Workflows.phases(workflow_session.workflow_type), phase - 1) do
    {_mod, opts} -> opts
    nil -> []
  end

opts =
  case Keyword.get(phase_def_opts, :allowed_tools) do
    nil -> opts
    tools -> Keyword.put(opts, :allowed_tools, tools)
  end
```

After:
```elixir
opts =
  case Enum.at(Destila.Workflows.phases(workflow_session.workflow_type), phase - 1) do
    %Destila.Workflow.Phase{allowed_tools: tools} when tools != [] ->
      Keyword.put(opts, :allowed_tools, tools)
    _ ->
      opts
  end
```

### Step 5: Move chat UI rendering to a function component

**File: `lib/destila_web/components/chat_components.ex`**

Add a new public function component `chat_phase/1` that contains the template currently in `AiConversationPhase.render/1`. This component:

- Accepts assigns: `workflow_session`, `messages`, `phase_number`, `phase_config` (the `%Phase{}` struct), `streaming_chunks`, `question_answers`, `metadata`, `current_step`
- Computes `phase_groups` and derived assigns inline (same as `AiConversationPhase.render/1` currently does)
- Renders the scrollable chat area, phase group sections, structured inputs, text input, and retry/cancel buttons
- All `phx-target` attributes are **removed** — events bubble to `WorkflowRunnerLive`
- The `.PhaseToggle` colocated hook moves into this component

The `target` assign is removed from all sub-components (`chat_message`, `text_input`, `single_select_input`, `multi_select_input`, `multi_question_input`, `chat_input`). Since there is no more LiveComponent, all events go directly to the LiveView.

### Step 6: Move event handlers and state to `WorkflowRunnerLive`

**File: `lib/destila_web/live/workflow_runner_live.ex`**

Add a new assign in `mount_session/2`:
```elixir
|> assign(:question_answers, %{})
```

Add `import DestilaWeb.ChatComponents` (already imported by `AiConversationPhase`, but now needed in the runner).

Move all 9 event handlers from `AiConversationPhase`:

1. **`send_text`** — same logic, uses `socket.assigns` directly instead of LiveComponent assigns. After sending, re-fetch messages and compute `current_step`.

2. **`select_single`** — delegates to `send_text` handler.

3. **`select_multi`** — joins selected items, delegates to `send_text`.

4. **`answer_question`** — updates `question_answers` assign on socket.

5. **`confirm_multi_answer`** — updates `question_answers` with multi-select value.

6. **`submit_all_answers`** — reads `question_answers`, builds response, delegates to `send_text`, resets `question_answers` to `%{}`.

7. **`retry_phase`** — calls `Engine.phase_retry/1` (same as before).

8. **`cancel_phase`** — stops ClaudeSession, updates phase_status (same as before).

Move `compute_current_step/2` from `AiConversationPhase` to a private function in the runner (or into a helper module if preferred). Recompute on:
- Mount
- After `send_text`
- After `handle_info({:workflow_session_updated, ...})`

Add assigns for `current_step` and `messages` (AI messages) in `mount_session/2`:
```elixir
|> assign_ai_state(workflow_session)
```

Create a private `assign_ai_state/2` function that loads AI messages and computes `current_step`:
```elixir
defp assign_ai_state(socket, ws) do
  messages = Destila.AI.list_messages_for_workflow_session(ws.id)
  current_step = compute_current_step(ws, messages)

  socket
  |> assign(:messages, messages)
  |> assign(:current_step, current_step)
end
```

Call `assign_ai_state` in the relevant `handle_info` clauses (`workflow_session_updated`, `metadata_updated`) to keep messages and current_step fresh.

### Step 7: Update `render_phase/1` in `WorkflowRunnerLive`

**File: `lib/destila_web/live/workflow_runner_live.ex`**

Replace the generic `render_phase/1` that mounts a LiveComponent with a direct function component call:

Before:
```elixir
defp render_phase(%{phases: phases, current_phase: current_phase} = assigns) do
  case Enum.at(phases, current_phase - 1) do
    {module, opts} ->
      assigns = assign(assigns, :phase_module, module)
      assigns = assign(assigns, :phase_opts, opts)
      ~H"""
      <.live_component
        module={@phase_module}
        id={"phase-#{@current_phase}"}
        ...
      />
      """
    ...
  end
end
```

After:
```elixir
defp render_phase(%{phases: phases, current_phase: current_phase} = assigns) do
  case Enum.at(phases, current_phase - 1) do
    %Destila.Workflow.Phase{} = phase ->
      assigns = assign(assigns, :phase_config, phase)
      ~H"""
      <.chat_phase
        workflow_session={@workflow_session}
        messages={@messages}
        phase_number={@current_phase}
        phase_config={@phase_config}
        streaming_chunks={@streaming_chunks}
        question_answers={@question_answers}
        metadata={@metadata}
        current_step={@current_step}
      />
      """
    nil ->
      ~H"""
      <div class="text-base-content/50 text-center py-12">
        Phase {@current_phase}
      </div>
      """
  end
end
```

### Step 8: Remove `target` from ChatComponents sub-components

**File: `lib/destila_web/components/chat_components.ex`**

Remove the `target` attr and all `phx-target={@target}` references from:
- `chat_message/1` (the confirm/decline advance buttons already target the parent — no change needed there)
- `text_input/1`
- `single_select_input/1`
- `multi_select_input/1`
- `multi_question_input/1`
- `chat_input/1`

All events now naturally bubble to `WorkflowRunnerLive`.

### Step 9: Update `Workflows` context dispatcher

**File: `lib/destila/workflows.ex`**

The `phases/1` function just delegates to the workflow module — no change needed. But `Workflows.phase_update_action/2` passes `ws` to the workflow module, which accesses `phases()` internally — this all works with structs already.

Verify that `Destila.Executions.Engine` doesn't pattern-match on `{module, opts}` anywhere. Currently it doesn't — it delegates to workflow modules via `Workflows.phase_start_action/1` and `Workflows.phase_update_action/2`.

### Step 10: Update unit tests

**File: `test/destila/workflow_test.exs`**

Update assertions that check the shape of `phases/0` return values. Currently tests assert on the tuple shape — update to assert on `%Phase{}` structs.

### Step 11: Update LiveView tests

**Files:**
- `test/destila_web/live/brainstorm_idea_workflow_live_test.exs`
- `test/destila_web/live/implement_general_prompt_workflow_live_test.exs`

These tests drive behavior through `WorkflowRunnerLive` (via `live/2`, `render_click`, etc.). Since user-facing behavior is identical, most tests should pass without changes. Potential adjustments:

- If any test references `AiConversationPhase` by name, update to reference the function component or remove the reference
- If any test uses `phx-target` selectors that targeted `@myself`, remove those selectors (events now go to the LiveView)

### Step 12: Delete `AiConversationPhase`

**File to delete: `lib/destila_web/live/phases/ai_conversation_phase.ex`**

Remove the file entirely. Verify no other module references it:
- `BrainstormIdeaWorkflow.phases/0` — updated in step 3
- `ImplementGeneralPromptWorkflow.phases/0` — updated in step 3
- Tests — updated in step 11
- No other references expected

### Step 13: Audit database schemas

Review these schemas for fields that only existed for the phase-module abstraction:

- **`phase_executions`** — `phase_name` (string) is still needed (stores the phase name for display). `phase_number` is still needed. No fields to remove.
- **`ai_sessions`** — `claude_session_id`, `worktree_path` are still needed for session resumption. No fields to remove.
- **`messages`** — `role`, `content`, `raw_response`, `selected`, `phase` are all still needed. No fields to remove.
- **`workflow_sessions`** — all fields still needed. No changes.

Result: **No schema changes needed.** The current schemas store runtime state, not module references.

### Step 14: Run `mix precommit`

Verify compilation, tests, and formatting all pass.

## Files to modify

1. **`lib/destila/workflow/phase.ex`** — NEW: `%Phase{}` struct definition
2. **`lib/destila/workflow.ex`** — Update type, callback, and `__using__` macro for `%Phase{}`
3. **`lib/destila/workflows/brainstorm_idea_workflow.ex`** — Return `%Phase{}` structs, update pattern matching
4. **`lib/destila/workflows/implement_general_prompt_workflow.ex`** — Return `%Phase{}` structs, update pattern matching
5. **`lib/destila/ai/claude_session.ex`** — Update `session_opts_for_workflow/3` for struct access
6. **`lib/destila_web/components/chat_components.ex`** — Add `chat_phase/1` function component, remove `target` from sub-components
7. **`lib/destila_web/live/workflow_runner_live.ex`** — Add chat event handlers, `question_answers`/`messages`/`current_step` assigns, update `render_phase/1`
8. **`lib/destila_web/live/phases/ai_conversation_phase.ex`** — DELETE
9. **`test/destila/workflow_test.exs`** — Update `%Phase{}` assertions
10. **`test/destila_web/live/brainstorm_idea_workflow_live_test.exs`** — Remove any `AiConversationPhase` references
11. **`test/destila_web/live/implement_general_prompt_workflow_live_test.exs`** — Remove any `AiConversationPhase` references

## Files confirmed unchanged

1. **Feature files** — user-visible behavior is identical
2. **`lib/destila/executions/engine.ex`** — delegates via `Workflows` context, no direct tuple access
3. **`lib/destila/executions.ex`** — no phase definition access
4. **`lib/destila/ai.ex`** — no phase definition access
5. **`lib/destila/workflows.ex`** — dispatcher functions remain the same (just delegates to modules)
6. **Database schemas and migrations** — no fields to add or remove
7. **`lib/destila_web/components/setup_components.ex`** — independent of phase module system

## Risks and mitigations

1. **Big bang change** — All files must be updated together since the `phases/0` return type changes globally. Mitigated by: only 2 workflows exist, and the change is mechanical (struct for tuple).

2. **`question_answers` state moves to LiveView** — `AiConversationPhase` held this in its own process. Moving to the LiveView socket is simpler (no cross-process state). The state is already per-session since each LiveView mounts one workflow session. Risk: forgetting to reset on phase advance. Mitigation: reset `question_answers` to `%{}` in `confirm_advance` handler.

3. **Event routing after removing `phx-target`** — All events currently targeted at `@myself` (the LiveComponent) will bubble to the LiveView. If any event name collides with an existing LiveView handler, it will be handled twice or incorrectly. Review: the LiveView's existing events are `edit_title`, `save_title`, `archive_session`, `unarchive_session`, `confirm_advance`, `decline_advance`, `mark_done`, `mark_undone`, `retry_setup`. The chat events are `send_text`, `select_single`, `select_multi`, `answer_question`, `confirm_multi_answer`, `submit_all_answers`, `retry_phase`, `cancel_phase`. **No collisions.**

4. **Message re-fetching performance** — `AiConversationPhase.update/2` fetched messages on every assign update. The new design should only fetch messages when needed (mount, after sending a message, after PubSub session update). This is actually a performance improvement.

5. **`chat_message` component's `target` attr** — currently used for `confirm_advance` and `decline_advance` buttons inside `chat_message`. These buttons already don't use `phx-target` (they go to the parent LiveView). Confirm this is the case in the current code before removing the `target` attr. If any sub-component does use `target` for these buttons, they'll naturally work without it since the LiveView already handles those events.
