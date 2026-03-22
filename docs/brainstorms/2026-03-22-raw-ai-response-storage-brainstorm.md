# Store Raw AI Responses on Messages

**Date:** 2026-03-22
**Status:** Ready for planning

## What We're Building

Refactor the Message schema to store raw AI agent responses and derive all display state at read time. This decouples storage from presentation, preserving full AI context for future UI changes without needing to re-generate non-deterministic prompts.

## Why This Approach

Currently, when the AI responds, we immediately extract and store derived fields (`input_type`, `options`, `questions`, `message_type`, cleaned `content`). The raw AI result is discarded. If we later change how we parse markers, render questions, or display responses, old messages are stuck with whatever was extracted at write time. Storing the raw response makes messages future-proof.

## Key Decisions

### 1. Message Schema (Simplified)

| Field | Type | Purpose |
|-------|------|---------|
| `id` | binary_id PK | |
| `prompt_id` | FK → prompts | |
| `role` | Ecto.Enum [:system, :user] | Who sent the message |
| `content` | text | Raw text — for user messages: their input; for AI messages: raw AI text including markers |
| `raw_response` | text (JSON) | Full AI result map (`text`, `result`, `session_id`, `mcp_tool_uses`, `is_error`). Only populated for AI (`:system` role) messages. `nil` for user messages and static workflow messages. |
| `selected` | text (JSON array) | User's selections for select inputs |
| `phase` | integer | Phase number (1-4). Replaces `step`. Used for grouping, querying, and deriving phase transitions in the UI. |
| `inserted_at` | utc_datetime_usec | |

**Fields removed** (derived at read time from `raw_response`):
- `input_type` — derived from `raw_response.mcp_tool_uses`
- `options` — derived from `raw_response.mcp_tool_uses`
- `questions` — derived from `raw_response.mcp_tool_uses`
- `message_type` — derived from markers in `content` (`<<READY_TO_ADVANCE>>`, `<<SKIP_PHASE>>`) and phase context (phase == steps_total → generated_prompt)

**Field renamed**: `step` → `phase` for clarity.

**Synthetic phase divider messages eliminated**: The UI derives phase breaks from transitions in `phase` number across sequential messages. No need to insert synthetic "Phase N — Name" messages.

### 2. Processing at Read Time

A context function `Messages.process/2` (or similar) takes a message struct and its prompt context, returns a map with derived display fields:

```elixir
%{
  content: "cleaned text without markers",
  input_type: :text | :single_select | :multi_select | :questions | nil,
  options: [%{label: ..., description: ...}] | nil,
  questions: [%{question: ..., input_type: ..., options: ...}] | nil,
  message_type: :phase_advance | :skip_phase | :generated_prompt | nil,
  phase_status_effect: :advance_suggested | :conversing | nil
}
```

This function:
- Strips `<<READY_TO_ADVANCE>>` / `<<SKIP_PHASE>>` markers from content
- Extracts questions/options from `raw_response.mcp_tool_uses`
- Determines `message_type` from markers and phase context
- Returns the display-ready data

### 3. What role Distinguishes

- `role: :user` — content is the user's text/selection. `raw_response` is nil.
- `role: :system` + `raw_response` present — AI response. Derive display from raw_response + content.
- `role: :system` + `raw_response` nil — Static workflow message (predefined step content). Use content directly.

### 4. Phase Number Instead of Phase Dividers

Replace synthetic phase divider messages with a `phase` integer on every message:
- UI groups messages by `phase` and renders dividers between groups
- Enables `WHERE phase = N` queries for loading specific phases
- Enables "extend a phase" — add more messages with the same phase number
- Phase names come from `ChoreTaskPhases.phase_name/1` (unchanged)

### 5. Content Field Strategy

For all messages, `content` stores the raw/unprocessed text:
- **User messages**: the user's typed text
- **AI messages**: the raw AI text including markers (`<<READY_TO_ADVANCE>>`, etc.)
- **Static workflow messages**: the predefined step content

The processing function strips markers for display. The raw text in `content` is useful for `build_conversation_context` (session resumption) where we want the full unmodified text.

## Scope

### In Scope
- Modify the single migration to reflect new schema (drop derived columns, add `raw_response`, rename `step` → `phase`)
- Update Message schema
- Create `Messages.process/2` processing function
- Update `handle_ai_query_result` and `trigger_ai_response` to store raw_response instead of derived fields
- Remove synthetic phase divider message insertion
- Update `ai_step_info` and `current_step_info` to use processed messages
- Update templates to use processed display data
- Update `phase_groups` to derive from `phase` field transitions

### Out of Scope
- Renaming `role: :system` to `role: :assistant` (follow-up)
- Changing how static workflow messages work
- UI redesign
