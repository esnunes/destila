---
title: "refactor: Replace text markers with session MCP tool"
type: refactor
date: 2026-03-27
---

# Replace `<<READY_TO_ADVANCE>>` and `<<SKIP_PHASE>>` markers with `session` MCP tool

## Overview

Replace the text-based marker system (`<<READY_TO_ADVANCE>>`, `<<SKIP_PHASE>>`) for phase transitions with a proper MCP tool call (`mcp__destila__session`). The AI currently signals phase transitions by embedding marker strings in response text which are then parsed out. This refactoring moves that signaling into the structured MCP tool infrastructure already used by `ask_user_question`.

## Problem Statement / Motivation

Text markers are a fragile mechanism — they rely on string parsing, can leak into displayed content if parsing fails, and mix control flow signals with content. The MCP tool infrastructure already provides a structured, typed way for the AI to communicate actions. Using a dedicated tool for phase transitions makes the intent explicit, the data structured, and the detection reliable.

## Proposed Solution

Add a `session` tool to the existing MCP server (`Destila.AI.Tools`) with two actions: `suggest_phase_complete` (replaces `<<READY_TO_ADVANCE>>`) and `phase_complete` (replaces `<<SKIP_PHASE>>`). Detect phase transitions by inspecting `mcp_tool_uses` in the AI response instead of scanning text. Update all prompt templates to instruct the AI to call the tool instead of emitting markers.

## Technical Approach

### Key Design Decisions

1. **Content at write time**: The worker stores the session tool's `message` as the message `content` field. This keeps `build_conversation_context/1` working unchanged (it reads `msg.content` directly). The `raw_response` still stores the full response for read-time derivation of `message_type`.

2. **No backward compatibility**: Per project convention, the DB can be reset freely. No need to handle old marker-based messages.

3. **Session tool priority**: If the AI calls both `session` and `ask_user_question` in the same response, the `session` tool takes priority for `message_type` derivation. Questions are suppressed. (Prompts should instruct the AI not to do this.)

4. **First tool wins**: If the AI calls `session` multiple times in one response, only the first call is used.

5. **Dual key format**: `extract_session_action/1` handles both atom keys (worker context, from `collect_with_mcp`) and string keys (display context, from DB JSON). The existing `normalize_keys/1` already converts structs to string-keyed maps when storing `raw_response`.

### Files to Change

| File | Change |
|---|---|
| `lib/destila/ai/tools.ex` | Add `session` tool definition |
| `lib/destila/ai/claude_session.ex` | Add `"mcp__destila__session"` to `@default_allowed_tools` |
| `lib/destila/ai.ex` | Replace `derive_phase_status/1`, `parse_markers/3`; add `extract_session_action/1`; update `process_message/2` |
| `lib/destila/workers/ai_query_worker.ex` | Replace text-based detection with tool-use detection |
| `lib/destila/workflows/prompt_chore_task_workflow.ex` | Update all prompt templates and `@tool_instructions` |
| `test/destila_web/live/chore_task_workflow_live_test.exs` | Update test helpers and stubs |
| `features/chore_task_workflow.feature` | No changes needed (scenarios describe behavior, not mechanism) |

---

## Implementation Phases

### Phase 1: Define the `session` tool and register it

**`lib/destila/ai/tools.ex`** — Add after the `ask_user_question` tool:

```elixir
tool :session,
     "Signal a phase transition in the workflow session. " <>
       "Call this tool when you believe the current phase is complete." do
  field(:action, :string,
    required: true,
    description:
      "One of: suggest_phase_complete (phase work is done, ask user to confirm), " <>
        "phase_complete (phase is definitively done or not applicable, auto-advance)"
  )

  field(:message, :string,
    required: true,
    description:
      "Context or reason for the action, e.g. 'No Gherkin scenarios needed for this task'"
  )

  def execute(_params) do
    {:ok, "Phase action recorded. Stop here and wait."}
  end
end
```

**`lib/destila/ai/claude_session.ex`** — Add to `@default_allowed_tools`:

```elixir
@default_allowed_tools [
  "Read",
  "Grep",
  "Glob",
  "Bash(git log:*)",
  "Bash(git show:*)",
  "mcp__destila__ask_user_question",
  "mcp__destila__session"
]
```

### Phase 2: Add `extract_session_action/1` to `Destila.AI`

Add a public helper that extracts the first session tool call from a result or raw_response. Must handle both atom-keyed (worker) and string-keyed (DB) formats:

```elixir
@session_tool_names ["session", "mcp__destila__session"]

def extract_session_action(%{mcp_tool_uses: tool_uses}) when is_list(tool_uses) do
  do_extract_session_action(tool_uses, :atom)
end

def extract_session_action(%{"mcp_tool_uses" => tool_uses}) when is_list(tool_uses) do
  do_extract_session_action(tool_uses, :string)
end

def extract_session_action(_), do: nil

defp do_extract_session_action(tool_uses, key_type) do
  {name_key, input_key, action_key, message_key} =
    case key_type do
      :atom -> {:name, :input, :action, :message}
      :string -> {"name", "input", "action", "message"}
    end

  Enum.find_value(tool_uses, fn tool ->
    name = if is_struct(tool), do: Map.get(tool, :name), else: tool[name_key]

    if name in @session_tool_names do
      input = if is_struct(tool), do: Map.get(tool, :input), else: tool[input_key]
      input = input || %{}
      %{action: input[action_key], message: input[message_key]}
    end
  end)
end
```

Note: `collect_with_mcp` stores `MCPToolUseBlock` structs (atom fields like `.name`, `.input`) in the result's `mcp_tool_uses` list. These structs get converted to string-keyed maps by `normalize_keys/1` when stored as `raw_response`. The helper must handle both forms.

### Phase 3: Replace `derive_phase_status/1` in `Destila.AI`

Change the signature from `derive_phase_status(text)` to `derive_phase_status(result)`:

```elixir
# Before (lines 142-148):
def derive_phase_status(text) do
  cond do
    String.contains?(text, "<<SKIP_PHASE>>") -> :conversing
    String.contains?(text, "<<READY_TO_ADVANCE>>") -> :advance_suggested
    true -> :conversing
  end
end

# After:
def derive_phase_status(result) do
  case extract_session_action(result) do
    %{action: "suggest_phase_complete"} -> :advance_suggested
    _ -> :conversing
  end
end
```

Note: `phase_complete` returns `:conversing` (same as the old `<<SKIP_PHASE>>` behavior) — the actual skip is handled separately in the worker.

### Phase 4: Replace `parse_markers/3` with `derive_message_type/3` in `Destila.AI`

```elixir
# Before (lines 197-215): parse_markers(text, phase, workflow_session) scanning text

# After:
defp derive_message_type(raw, phase, workflow_session) do
  cond do
    phase == workflow_session.total_phases ->
      # Final phase is always :generated_prompt, no session tool expected
      {nil, :generated_prompt}

    session = extract_session_action(raw) ->
      case session.action do
        "suggest_phase_complete" ->
          msg = session.message || "Ready to move to the next phase."
          {msg, :phase_advance}

        "phase_complete" ->
          msg = session.message || "Skipping this phase."
          {msg, :skip_phase}

        _ ->
          {nil, nil}
      end

    true ->
      {nil, nil}
  end
end
```

Returns `{override_content, message_type}` where `override_content` is the session tool's message (or `nil` if no session tool was called).

### Phase 5: Update `process_message/2` in `Destila.AI`

```elixir
def process_message(%Message{role: :system, raw_response: raw} = msg, workflow_session)
    when is_map(raw) do
  {override_content, message_type} = derive_message_type(raw, msg.phase, workflow_session)
  {input_type, options, questions} = extract_tool_input(raw)

  # Use session tool message if present, otherwise use stored content
  content = override_content || String.trim(msg.content)

  # For generated_prompt, always use the stored content (AI's text output)
  content =
    if message_type == :generated_prompt do
      String.trim(msg.content)
    else
      content
    end

  # If questions were extracted and content is empty/placeholder, derive from questions
  content =
    if questions != [] and (content == "" or content == "Waiting for your answer.") do
      questions |> Enum.map(& &1.question) |> Enum.join("\n\n")
    else
      content
    end

  # When session tool is active, suppress question UI
  {input_type, options, questions} =
    if message_type in [:phase_advance, :skip_phase] do
      {:text, nil, []}
    else
      {input_type, options, questions}
    end

  %{
    id: msg.id,
    role: :system,
    phase: msg.phase,
    content: content,
    selected: nil,
    inserted_at: msg.inserted_at,
    message_type: message_type,
    input_type: input_type,
    options: options,
    questions: questions
  }
end
```

### Phase 6: Update `AiQueryWorker` to use tool-based detection

```elixir
# Before (lines 42-68):
defp handle_query(ws, ai_session_record, phase, session, query) do
  case Destila.AI.ClaudeSession.query(session, query) do
    {:ok, result} ->
      response_text = AI.response_text(result)
      new_phase_status = AI.derive_phase_status(response_text)
      # ... create_message ...
      if String.contains?(response_text, "<<SKIP_PHASE>>") do
        handle_skip_phase(ws.id, phase)
      else
        Workflows.update_workflow_session(ws.id, %{phase_status: new_phase_status})
      end

# After:
defp handle_query(ws, ai_session_record, phase, session, query) do
  case Destila.AI.ClaudeSession.query(session, query) do
    {:ok, result} ->
      response_text = AI.response_text(result)
      session_action = AI.extract_session_action(result)

      # Use session tool message as content when present, fallback to response text
      content =
        case session_action do
          %{message: msg} when is_binary(msg) and msg != "" -> msg
          _ -> response_text
        end

      AI.create_message(ai_session_record.id, %{
        role: :system,
        content: content,
        raw_response: result,
        phase: phase
      })

      if result[:session_id] do
        AI.update_ai_session(ai_session_record, %{
          claude_session_id: result[:session_id]
        })
      end

      case session_action do
        %{action: "phase_complete"} ->
          handle_skip_phase(ws.id, phase)

        %{action: "suggest_phase_complete"} ->
          Workflows.update_workflow_session(ws.id, %{phase_status: :advance_suggested})

        _ ->
          Workflows.update_workflow_session(ws.id, %{phase_status: :conversing})
      end

      :ok
    # ... error handling unchanged ...
  end
end
```

Note: `derive_phase_status/1` is no longer called from the worker — the logic is inlined since the worker already extracts `session_action` for the skip check. `derive_phase_status/1` can be removed or kept if used elsewhere. Check for callers before removing.

### Phase 7: Update prompt templates

**`@tool_instructions`** — Add session tool instructions:

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

IMPORTANT: Never call `mcp__destila__session` in the same response as unanswered questions. \
If you still need information from the user, ask your questions and wait for their answers \
before signaling phase completion.

IMPORTANT: Never call both `mcp__destila__ask_user_question` and `mcp__destila__session` \
in the same response.
"""
```

**`task_description_prompt/1`** — Replace lines 105-110:

```elixir
# Before:
# Keep your questions concise and specific. When you believe you have a clear understanding \
# of the task, end your message with <<READY_TO_ADVANCE>>
#
# IMPORTANT: Never use <<READY_TO_ADVANCE>> in a message that contains unanswered questions. \
# If you still need information from the user, ask your questions and wait for their answers \
# before using the marker.

# After:
Keep your questions concise and specific. When you believe you have a clear understanding \
of the task, call the `mcp__destila__session` tool with `action: "suggest_phase_complete"` \
and a message summarizing your understanding.
```

**`gherkin_review_prompt/1`** — Replace lines 142-154:

```elixir
# After:
1. If .feature files exist, review them against the task discussed.
   - If changes are needed, propose specific additions, modifications, or removals.
   - Discuss with the user until they agree on the changes.
   - When done, call `mcp__destila__session` with `action: "suggest_phase_complete"`.

2. If no .feature files exist in the repository:
   - Ask the user if they want to define new Gherkin scenarios for this task.
   - If yes, help them draft scenarios and call `mcp__destila__session` with \
     `action: "suggest_phase_complete"`.
   - If no, call `mcp__destila__session` with `action: "phase_complete"` and a \
     message explaining why.

3. If the task doesn't require Gherkin changes:
   - Call `mcp__destila__session` with `action: "phase_complete"` and a \
     message explaining why.
```

**`technical_concerns_prompt/1`** — Replace lines 173-178:

```elixir
# After:
When the technical approach is sufficiently clear, call the `mcp__destila__session` \
tool with `action: "suggest_phase_complete"` and a message summarizing the agreed approach.
```

**`prompt_generation_prompt/1`** — Replace line 200:

```elixir
# Before:
# Do NOT end with <<READY_TO_ADVANCE>> — the user will mark this as done when satisfied.

# After:
Do NOT call the `mcp__destila__session` tool — the user will mark this phase as done manually.
```

### Phase 8: Update tests

**`create_session_in_phase/2` helper** — Replace marker in content with tool use in raw_response:

```elixir
# Before (lines 42-81):
last_content =
  if Keyword.get(opts, :last_message_type) == :phase_advance,
    do: "I have some questions about this task. <<READY_TO_ADVANCE>>",
    else: "I have some questions about this task."

# ...
raw_response =
  if Keyword.get(opts, :last_message_type) != nil,
    do: %{"text" => last_content, "result" => last_content, "mcp_tool_uses" => [], ...}

# After:
last_content = "I have some questions about this task."

session_tool_use =
  case Keyword.get(opts, :last_message_type) do
    :phase_advance ->
      [%{"name" => "mcp__destila__session",
         "input" => %{"action" => "suggest_phase_complete",
                       "message" => "Task description is clear."}}]
    :skip_phase ->
      [%{"name" => "mcp__destila__session",
         "input" => %{"action" => "phase_complete",
                       "message" => "Skipping this phase."}}]
    _ ->
      []
  end

raw_response =
  if Keyword.get(opts, :last_message_type) != nil,
    do: %{"text" => last_content, "result" => last_content,
          "mcp_tool_uses" => session_tool_use, "is_error" => false}
```

When `last_message_type` is `:phase_advance`, store `content` as the tool's message (since that's what the worker now does):

```elixir
content_for_db =
  case Keyword.get(opts, :last_message_type) do
    :phase_advance -> "Task description is clear."
    :skip_phase -> "Skipping this phase."
    _ -> last_content
  end
```

**Skip phase test (lines 246-279)** — Update ClaudeCode stub to return session tool use:

```elixir
# Before:
ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
  n = Agent.get_and_update(call_count, fn n -> {n, n + 1} end)
  text =
    if n == 0,
      do: "No Gherkin scenarios needed for this task. <<SKIP_PHASE>>",
      else: "Let's discuss the technical approach."
  [ClaudeCode.Test.text(text), ClaudeCode.Test.result(text)]
end)

# After:
ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
  n = Agent.get_and_update(call_count, fn n -> {n, n + 1} end)

  if n == 0 do
    # Phase 4: AI skips Gherkin review via session tool
    [
      ClaudeCode.Test.text("No Gherkin scenarios needed."),
      ClaudeCode.Test.mcp_tool_use("mcp__destila__session", %{
        "action" => "phase_complete",
        "message" => "No Gherkin scenarios needed for this task."
      }),
      ClaudeCode.Test.result("No Gherkin scenarios needed.")
    ]
  else
    text = "Let's discuss the technical approach."
    [ClaudeCode.Test.text(text), ClaudeCode.Test.result(text)]
  end
end)
```

> **Note**: Verify that `ClaudeCode.Test.mcp_tool_use/2` exists. If not, construct the struct manually:
> ```elixir
> %ClaudeCode.Content.MCPToolUseBlock{
>   id: "tool_use_#{System.unique_integer([:positive])}",
>   name: "mcp__destila__session",
>   input: %{"action" => "phase_complete", "message" => "..."},
>   server_name: "destila"
> }
> ```
> Or use `%ClaudeCode.Content.ToolUseBlock{name: "mcp__destila__session", ...}` — both are captured by `extract_content/1` in `collect_with_mcp`.

### Phase 9: Clean up dead code

After all changes are verified:

- [ ] Remove `parse_markers/3` from `ai.ex`
- [ ] Remove `derive_phase_status/1` from `ai.ex` (if no longer called — check for callers)
- [ ] Grep the entire codebase for `<<READY_TO_ADVANCE>>`, `<<SKIP_PHASE>>`, `READY_TO_ADVANCE`, `SKIP_PHASE`, `parse_markers`, `derive_phase_status` — ensure zero results

## Acceptance Criteria

- [ ] `session` tool is defined in `Destila.AI.Tools` with `action` and `message` fields
- [ ] `"mcp__destila__session"` is in `@default_allowed_tools`
- [ ] Worker detects `suggest_phase_complete` → sets `:advance_suggested` on workflow session
- [ ] Worker detects `phase_complete` → calls `handle_skip_phase` and auto-advances
- [ ] Worker stores session tool's `message` as message `content`
- [ ] Display-time `process_message/2` derives `message_type` from `mcp_tool_uses`, not text
- [ ] `:phase_advance` message type renders confirm/decline buttons (unchanged UX)
- [ ] `:skip_phase` auto-advances without user confirmation (unchanged UX)
- [ ] Final phase (`:generated_prompt`) is unaffected by session tool
- [ ] All prompt templates reference `mcp__destila__session` instead of markers
- [ ] No marker strings (`<<READY_TO_ADVANCE>>`, `<<SKIP_PHASE>>`) remain anywhere in the codebase
- [ ] All existing tests pass with updated stubs
- [ ] `mix precommit` passes

## Dependencies & Risks

- **ClaudeCode.Test helpers**: The test stubs need to produce `MCPToolUseBlock` or `ToolUseBlock` structs in the stream. If `ClaudeCode.Test.mcp_tool_use/2` doesn't exist, manual struct construction is needed. Check the `ClaudeCode.Test` module before implementing.
- **AI behavior change**: The AI must reliably call the `session` tool instead of embedding text markers. Prompt instructions must be clear enough. Monitor initial sessions for correct tool usage.
- **DB reset required**: Existing sessions with marker-based messages will display incorrectly after migration. Reset the DB.

## References

### Internal References

- `lib/destila/ai/tools.ex` — MCP tool definition pattern (lines 10-40)
- `lib/destila/ai/claude_session.ex:11-18` — `@default_allowed_tools`
- `lib/destila/ai/claude_session.ex:244-283` — `collect_with_mcp/1` and `extract_content/1`
- `lib/destila/ai.ex:86-148` — `process_message/2` and `derive_phase_status/1`
- `lib/destila/ai.ex:197-253` — `parse_markers/3` and `extract_tool_input/1`
- `lib/destila/workers/ai_query_worker.ex:42-85` — `handle_query/5` with marker detection
- `lib/destila/workflows/prompt_chore_task_workflow.ex:65-202` — prompt templates
- `test/destila_web/live/chore_task_workflow_live_test.exs:39-92` — test helper
- `features/chore_task_workflow.feature:47-70` — phase transition scenarios
