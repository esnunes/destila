---
name: Code Quality
always: false
---
Write code that is simple, direct, and minimal. Do NOT write unnecessary
defensive code — no redundant nil checks, fallback values, error handling,
or validation for scenarios that cannot happen. Trust internal code and
framework guarantees. Only validate at system boundaries (user input,
external APIs). Three simple lines are better than a premature abstraction.
Do not add features, configurability, or "improvements" beyond what the
plan specifies.
