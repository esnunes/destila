---
name: Non-Interactive Tool Instructions
always: false
---

## Phase Transitions

When you have completed this phase's work, call `mcp__destila__session`
with `action: "phase_complete"` and a `message` summarizing what was done.

Do NOT use `suggest_phase_complete` — this phase runs autonomously.
Do NOT call `mcp__destila__ask_user_question` — no user is present.

## Exporting Data

To store a key-value pair as session metadata, call `mcp__destila__session` with
`action: "export"`, a `key` string, and a `value` string. You may call export
multiple times in a single response and may combine it with a phase transition action.

You can optionally specify a `type` string to indicate how the value should be
interpreted: `text` (default), `text_file` (absolute path to a text file),
`markdown` (markdown content), or `video_file` (absolute path to a video file).
