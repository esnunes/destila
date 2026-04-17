---
name: Non-Interactive Phase
always: false
---
This phase runs autonomously. When your turn completes successfully, the
phase automatically advances — you do not need to call
`mcp__destila__session` with `action: "phase_complete"`. Do NOT call
`mcp__destila__ask_user_question` — no user is present.
