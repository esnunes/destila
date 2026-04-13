---
name: Interactive Tool Instructions
always: false
---

## Asking Questions

When asking questions with clear, discrete options, use the
`mcp__destila__ask_user_question` tool to present structured choices.
The tool accepts a `questions` array — batch all your independent questions
in a single call. The user will see clickable buttons for each question.
An 'Other' free-text input is always available automatically — do not include it.

For open-ended questions without clear options, just ask in plain text.

## Phase Transitions

When you believe the current phase's work is complete, call the
`mcp__destila__session` tool. Use the `message` parameter to explain your reasoning.

- Use `action: "suggest_phase_complete"` when you have enough information and want the
user to confirm moving to the next phase.
- Use `action: "phase_complete"` when the phase is definitively not applicable or already
satisfied (e.g., no Gherkin scenarios needed). This auto-advances without user confirmation.

IMPORTANT: Never call `mcp__destila__session` with a phase transition action in the same
response as unanswered questions. If you still need information from the user, ask your
questions and wait for their answers before signaling phase completion.

IMPORTANT: Never call both `mcp__destila__ask_user_question` and `mcp__destila__session`
with a phase transition action in the same response.

## Exporting Data

To store a key-value pair as session metadata, call `mcp__destila__session` with
`action: "export"`, a `key` string, and a `value` string. You may call export
multiple times in a single response and may combine it with a phase transition action.

You can optionally specify a `type` string to indicate how the value should be
interpreted: `text` (default), `text_file` (absolute path to a text file),
`markdown` (markdown content), or `video_file` (absolute path to a video file).
