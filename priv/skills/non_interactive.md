---
name: Non-Interactive Phase
always: false
---

This phase runs autonomously. When this phase's work is complete, call
`mcp__destila__session` with `action: "phase_complete"` and a `message`
summarizing what was done. Do NOT use `suggest_phase_complete`.
Do NOT call `mcp__destila__ask_user_question` — no user is present.
