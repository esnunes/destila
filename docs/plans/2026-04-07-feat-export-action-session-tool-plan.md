---
title: "feat: Add export action to session MCP tool"
type: feat
date: 2026-04-07
---

# feat: Add `export` action to the `:session` MCP AI tool

## Overview

The `:session` tool currently supports two actions: `suggest_phase_complete` and `phase_complete`. This adds a third action — `export` — that lets the AI store exported metadata via tool calls instead of workflows doing it programmatically. After this change, the AI is responsible for exporting data and `BrainstormIdeaWorkflow.handle_response/3` is removed.

## Current state

- **Tool definition** (`lib/destila/ai/tools.ex:42-61`): The `:session` tool has `action` and `message` string fields. The `execute/1` callback is a no-op — real processing happens downstream.
- **Downstream processing**: `ResponseProcessor.extract_session_action/1` finds the first session tool use and returns `%{action: ..., message: ...}`. `Conversation.phase_update/2` and `ResponseProcessor.derive_message_type/3` use this to drive phase transitions. The Engine acts on the returned status (`:phase_complete`, `:suggest_phase_complete`, `:awaiting_input`).
- **BrainstormIdeaWorkflow**: The only workflow with a `handle_response/3` override (line 46). It calls `Workflows.upsert_metadata/5` to store the generated prompt as exported metadata for the "Prompt Generation" phase.
- **ImplementGeneralPromptWorkflow**: Does NOT override `handle_response/3` — uses the default no-op.
- **`handle_response` hook**: Called from `Conversation.phase_update/2` (line 82) after saving the AI message. It receives `(ws, phase_number, response_text)`.

## Key design decisions

### 1. The `export` action uses different fields than phase-transition actions

Phase-transition actions use `action` + `message`. The `export` action uses `action` + `key` + `value`. Since the tool definition is a single schema shared across all actions, we add `key` and `value` as optional fields alongside the existing `message` field. The `execute/1` callback remains a no-op.

### 2. Multiple `export` calls per response are processed, not just the first one

`extract_session_action/1` currently uses `Enum.find_value` (returns the first match). For `export`, we need to collect ALL session tool uses with `action: "export"`. We add a new function `extract_export_actions/1` that returns a list of `%{key: ..., value: ...}` maps — one per export call.

### 3. Export processing happens in `Conversation.phase_update/2`

This is where the workflow session context is available (`ws.id`, `ws.current_phase`, `ws.workflow_type`) and where `handle_response` is already called. We process exports here, before the phase-transition case statement. This means exports are persisted even if a `phase_complete` action appears in the same response.

### 4. Phase name is auto-inferred from current workflow session state

The AI doesn't pass a phase name. We resolve it from `ws.workflow_type` and `ws.current_phase` using the existing `Workflows.phase_name/2` function.

### 5. `handle_response` hook is removed entirely

After this change, `BrainstormIdeaWorkflow` no longer needs its `handle_response/3` override because the AI exports metadata via the tool. The `handle_response` callback in the `Workflow` behaviour, its default implementation, and the call site in `Conversation.phase_update/2` are all removed. This simplifies the architecture — workflows become purely declarative (phases + prompts) with no imperative hooks.

### 6. The prompt instructs the AI to use `export`

The "Prompt Generation" phase prompt in `BrainstormIdeaWorkflow` is updated to instruct the AI to call `mcp__destila__session` with `action: "export"`, `key: "prompt_generated"`, and the prompt text as `value`. The `@tool_instructions` module attribute is updated to document the `export` action for all phases.

### 7. `derive_message_type/3` ignores `export` actions

The `export` action is not a phase transition. `derive_message_type/3` already returns `{nil, nil}` for unknown actions (the `_ ->` clause on line 161). Since `extract_session_action/1` returns the first session tool use (which could be `export`), we need to ensure that when `export` is the only session action, `derive_message_type` returns `{nil, nil}`. When `export` co-occurs with `phase_complete` or `suggest_phase_complete`, the phase-transition action should take precedence.

**Approach:** Modify `extract_session_action/1` to skip `export` actions — it should only return phase-transition actions. The new `extract_export_actions/1` handles exports separately.

## Changes

### Step 1: Extend the `:session` tool definition

**File:** `lib/destila/ai/tools.ex`

Add `key` and `value` fields to the `:session` tool. Make `message` optional (not required for `export`).

```elixir
tool :session,
     "Signal a phase transition or export metadata in the workflow session. " <>
       "Call this tool to advance phases or store key-value outputs." do
  field(:action, :string,
    required: true,
    description:
      "One of: suggest_phase_complete (phase work is done, ask user to confirm), " <>
        "phase_complete (phase is definitively done or not applicable, auto-advance), " <>
        "export (store a key-value pair as exported session metadata)"
  )

  field(:message, :string,
    description:
      "Context or reason for the action. Required for suggest_phase_complete and phase_complete."
  )

  field(:key, :string,
    description:
      "Metadata key for the export action, e.g. 'prompt_generated'. Required for export."
  )

  field(:value, :string,
    description:
      "Metadata value for the export action. Required for export."
  )

  def execute(_params) do
    {:ok, "Action recorded."}
  end
end
```

Key changes:
- Tool description updated to mention metadata export
- `message` is no longer `required: true` — export doesn't need it
- New `key` and `value` fields
- `execute/1` response simplified (works for all actions)

### Step 2: Add `extract_export_actions/1` to `ResponseProcessor`

**File:** `lib/destila/ai/response_processor.ex`

Add a new public function that extracts all `export` actions from the tool uses list:

```elixir
@doc """
Extracts all export actions from an AI result's MCP tool uses.

Returns a list of `%{key: key, value: value}` maps.
"""
def extract_export_actions(%{mcp_tool_uses: tool_uses}) when is_list(tool_uses) do
  do_extract_export_actions(tool_uses)
end

def extract_export_actions(%{"mcp_tool_uses" => tool_uses}) when is_list(tool_uses) do
  do_extract_export_actions(tool_uses)
end

def extract_export_actions(_), do: []

defp do_extract_export_actions(tool_uses) do
  Enum.flat_map(tool_uses, fn tool ->
    name = access(tool, :name)

    if name in @session_tool_names do
      input = access(tool, :input) || %{}

      if access(input, :action) == "export" do
        [%{key: access(input, :key), value: access(input, :value)}]
      else
        []
      end
    else
      []
    end
  end)
end
```

### Step 3: Update `extract_session_action/1` to skip `export`

**File:** `lib/destila/ai/response_processor.ex`

Modify `do_extract_session_action/1` to skip tool uses where `action == "export"`:

```elixir
defp do_extract_session_action(tool_uses) do
  Enum.find_value(tool_uses, fn tool ->
    name = access(tool, :name)

    if name in @session_tool_names do
      input = access(tool, :input) || %{}
      action = access(input, :action)

      # Skip export actions — they're handled by extract_export_actions/1
      if action != "export" do
        %{action: action, message: access(input, :message)}
      end
    end
  end)
end
```

This ensures `derive_message_type/3` and `Conversation.phase_update/2` only see phase-transition actions.

### Step 4: Process exports in `Conversation.phase_update/2`

**File:** `lib/destila/ai/conversation.ex`

In the `phase_update(ws, %{ai_result: result})` clause, after saving the message and before the phase-transition case statement, process all export actions:

```elixir
def phase_update(ws, %{ai_result: result}) do
  phase_number = ws.current_phase
  ai_session = AI.get_ai_session_for_workflow(ws.id)

  if ai_session do
    response_text = ResponseProcessor.response_text(result)
    session_action = ResponseProcessor.extract_session_action(result)

    content =
      case session_action do
        %{message: msg} when is_binary(msg) and msg != "" -> msg
        _ -> response_text
      end

    AI.create_message(ai_session.id, %{
      role: :system,
      content: content,
      raw_response: result,
      phase: phase_number,
      workflow_session_id: ws.id
    })

    if result[:session_id] do
      AI.update_ai_session(ai_session, %{claude_session_id: result[:session_id]})
    end

    # Process export actions
    export_actions = ResponseProcessor.extract_export_actions(result)

    if export_actions != [] do
      phase_name =
        Workflows.phase_name(ws.workflow_type, phase_number) || "Phase #{phase_number}"

      for %{key: key, value: value} <- export_actions, key != nil do
        Workflows.upsert_metadata(
          ws.id,
          phase_name,
          key,
          %{"text" => value},
          exported: true
        )
      end
    end

    case session_action do
      %{action: "phase_complete"} -> :phase_complete
      %{action: "suggest_phase_complete"} -> :suggest_phase_complete
      _ -> :awaiting_input
    end
  else
    :awaiting_input
  end
end
```

Key details:
- Exports are processed BEFORE the phase-transition case statement, so they persist even when `phase_complete` is in the same response
- Phase name is resolved via `Workflows.phase_name/2` (same pattern as `BrainstormIdeaWorkflow.handle_response/3` used)
- Value is wrapped as `%{"text" => value}` per the existing convention
- All exports are marked `exported: true`
- `key != nil` guard skips malformed export calls

### Step 5: Remove `handle_response` hook

#### 5a. Remove the override in `BrainstormIdeaWorkflow`

**File:** `lib/destila/workflows/brainstorm_idea_workflow.ex`

Delete the entire `handle_response/3` function (lines 46-64).

#### 5b. Remove the callback from the `Workflow` behaviour

**File:** `lib/destila/workflows/workflow.ex`

- Remove the `@callback handle_response/3` definition (lines 60-64)
- Remove the default `def handle_response(...)` in the `__using__` macro (line 90)
- Remove `handle_response: 3` from the `defoverridable` list (line 92)

#### 5c. Remove the call site in `Conversation.phase_update/2`

**File:** `lib/destila/ai/conversation.ex`

Remove these two lines (currently lines 81-82):

```elixir
# DELETE: workflow_module = Workflows.workflow_module(ws.workflow_type)
# DELETE: workflow_module.handle_response(ws, phase_number, response_text)
```

#### 5d. Keep `workflow_module/1` in `Workflows`

`workflow_module/1` is used as a delegation helper throughout `Workflows` (for `phases/1`, `phase_name/2`, `default_title/1`, etc.). Only the `handle_response` call in `Conversation` is removed — the function itself stays.

### Step 6: Update the "Prompt Generation" phase prompt

**File:** `lib/destila/workflows/brainstorm_idea_workflow.ex`

Update `prompt_generation_prompt/1` to instruct the AI to export the generated prompt:

```elixir
defp prompt_generation_prompt(_workflow_session) do
  """
  Generate a high-level implementation prompt based on the entire conversation so far. \
  This prompt should be ready to hand to a developer or coding agent.

  The prompt should include:
  - A clear description of what needs to be done
  - The technical approach to take
  - Any Gherkin scenarios that were discussed
  - Constraints and edge cases to handle

  The prompt should NOT include:
  - Detailed task lists or step-by-step instructions
  - Database schema designs
  - File-by-file change lists
  - Time estimates

  IMPORTANT: Output ONLY the prompt itself — no introductory text, headers, footers, \
  or commentary around it. Do not wrap it in a code block. Do not say "Here is the prompt:" \
  or "Let me know if you'd like changes." Just the prompt content, nothing else.

  After outputting the prompt, call `mcp__destila__session` with `action: "export"`, \
  `key: "prompt_generated"`, and `value` set to the full prompt text you just generated.

  The user may ask you to refine it. Each time you output a revised prompt, export it again \
  with the same key to update the stored value.

  Do NOT call the `mcp__destila__session` tool with `suggest_phase_complete` or \
  `phase_complete` — the user will mark this phase as done manually.
  """
end
```

### Step 7: Update `@tool_instructions` to document `export`

**File:** `lib/destila/workflows/brainstorm_idea_workflow.ex`

Update the `@tool_instructions` module attribute to include the `export` action:

```elixir
@tool_instructions """

## Asking Questions

When asking questions with clear, discrete options, use the \
`mcp__destila__ask_user_question` tool to present structured choices. \
The tool accepts a `questions` array — batch all your independent questions \
in a single call. The user will see clickable buttons for each question. \
An 'Other' free-text input is always available automatically — do not include it.

For open-ended questions without clear options, just ask in plain text.

## Phase Transitions

When you believe the current phase's work is complete, call the \
`mcp__destila__session` tool. Use the `message` parameter to explain your reasoning.

- Use `action: "suggest_phase_complete"` when you have enough information and want the \
user to confirm moving to the next phase.
- Use `action: "phase_complete"` when the phase is definitively not applicable or already \
satisfied (e.g., no Gherkin scenarios needed). This auto-advances without user confirmation.

IMPORTANT: Never call `mcp__destila__session` with a phase transition action in the same \
response as unanswered questions. If you still need information from the user, ask your \
questions and wait for their answers before signaling phase completion.

IMPORTANT: Never call both `mcp__destila__ask_user_question` and `mcp__destila__session` \
with a phase transition action in the same response.

## Exporting Data

To store a key-value pair as session metadata, call `mcp__destila__session` with \
`action: "export"`, a `key` string, and a `value` string. You may call export \
multiple times in a single response and may combine it with a phase transition action.
"""
```

### Step 8: Run `mix precommit`

Verify compilation, formatting, and tests pass.

## What does NOT change

- **Gherkin feature files**: The `exported_metadata.feature` scenarios test user-observable behavior (metadata appears in sidebar, updates in real-time) which is unchanged regardless of whether metadata is stored by workflow code or by the AI via the `export` tool action.
- **`Workflows.upsert_metadata/5`**: The function stays — it's still called by `Conversation.phase_update/2` (now for export processing) and by `create_workflow_session/1` (for storing initial input metadata).
- **`Workflows.create_workflow_session/1` metadata calls**: The `upsert_metadata` calls at lines 118-121 store the user's initial input and source session reference during creation. These are NOT exports from the AI — they stay.
- **`ResponseProcessor.derive_message_type/3`**: The `_ ->` fallback clause (line 160-161) already returns `{nil, nil}` for unknown actions. With Step 3's change to skip `export` in `extract_session_action/1`, this fallback won't even see `export` actions.

## Execution order

1. Steps 1-3 (tool definition + ResponseProcessor) — extend the tool and add extraction logic
2. Step 4 (Conversation) — wire up export processing
3. Steps 5-6 (remove handle_response + update prompt) — migration from programmatic to AI-driven exports
4. Step 7 (tool instructions) — document the new action
5. Step 8 (precommit) — validate

## Done when

- The `:session` tool accepts `action: "export"` with `key` and `value` parameters
- All `export` tool uses in an AI response are processed as exported metadata
- Phase name is auto-inferred — the AI doesn't pass it
- `export` can co-occur with `phase_complete` or `suggest_phase_complete` in the same response
- `BrainstormIdeaWorkflow.handle_response/3` is removed
- The `handle_response` callback is removed from the `Workflow` behaviour
- The "Prompt Generation" prompt instructs the AI to use `export`
- `@tool_instructions` documents the `export` action
- `mix precommit` passes
