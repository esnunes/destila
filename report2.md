# Destila — Refactoring Recommendations (Revised)

This report supersedes Part 3 of `report.md`. Every item has been reevaluated against the greenfield design in Part 2b. Items from the original report are marked as **kept**, **upgraded**, **superseded**, or **dropped**. New items drawn from the greenfield design are marked **new**.

The guiding principle: each refactor should move the codebase closer to the greenfield architecture without requiring a full rewrite. They are ordered so earlier items unlock or simplify later ones.

---

## Tier 1 — Foundation

These create the structural bedrock that all subsequent refactors build on.

### F1. `Ecto.Enum` for `PhaseExecution.status`

**What:** Change `phase_executions.status` from a plain `:string` to `Ecto.Enum, values: [:pending, :processing, :awaiting_input, :awaiting_confirmation, :completed, :skipped, :failed]`.

**Why:** Every subsequent refactor that touches phase execution status will be safer with compile-time atom matching instead of string literals. This is a prerequisite for F2 (state machine) and F3 (eliminating dual state), because both need consistent atom-based types.

**Effort:** Small. **Risk:** Low.

---

### F2. Explicit phase execution state machine

**What:** Create a `Destila.Executions.StateMachine` module that declares all valid phase execution transitions as data, provides a validated `transition!/3` function, and becomes the single entry point for all status changes.

**Why:** The current state machine is implicit — scattered across Engine control flow. Nothing prevents invalid transitions. The StateMachine module gives validated transitions, a single source of truth, and documented behavior. It's the practical stepping stone toward `gen_statem`.

**Transition map:**

```
pending:                [:processing]
processing:             [:awaiting_input, :awaiting_confirmation, :completed, :skipped, :failed]
awaiting_input:         [:processing]
awaiting_confirmation:  [:completed, :awaiting_input]
failed:                 [:processing]
completed:              []
skipped:                []
```

**Effort:** Small. **Risk:** Low.

---

### F3. Eliminate `phase_status` from `workflow_sessions`

**What:** Remove the `phase_status` column from `workflow_sessions`. Derive it from the latest `phase_execution` record via `Executions.current_status/1`.

**Why:** The Engine currently writes to both `workflow_sessions.phase_status` and `phase_executions.status` in 6+ places. After F2, all phase execution writes go through `StateMachine.transition!/3`. With F3, the Engine stops writing `phase_status` entirely — one validated write path for status changes.

**Effort:** Medium. **Risk:** Medium.

---

### F4. Messages FK directly to `workflow_sessions`

**What:** Add `workflow_session_id` directly to the `messages` table. Keep `ai_session_id` for provenance. Stop joining through `ai_sessions` for queries.

**Why:** Listing messages for a session currently requires joining through `ai_sessions`. When `session_strategy: :new` creates a fresh AI session, messages split across multiple records. Direct FK simplifies queries.

**Effort:** Small. **Risk:** Low.

---

## Tier 2 — Separation of Concerns

### S1. Extract `AI.ResponseProcessor`

**What:** Move all response processing logic from `Destila.AI` into `Destila.AI.ResponseProcessor` (`process_message/2`, `extract_session_action/1`, `derive_message_type/4`, etc.).

**Why:** Response processing is presentation logic living in the data access layer. Extracting it makes `Destila.AI` a thin CRUD module and the processor independently testable.

**Effort:** Small. **Risk:** Low.

---

### ~~S2. Separate infrastructure state from domain metadata~~

**Dropped.** After W1a and W1b, all infrastructure metadata entries (`title_gen`, `repo_sync`, `worktree`) are eliminated entirely. `session_metadata` becomes purely domain data.

---

### S3. Move `session_opts_for_workflow/3` out of `ClaudeSession`

**What:** Move to `AI.Conversation` or a new `AI.SessionConfig` module. The GenServer should only handle session lifecycle and streaming, not read workflow phases or AI session records.

**Effort:** Small. **Risk:** Low.

---

### S4. Plugin management at application boot

**What:** Move plugin marketplace registration, installation, and enabling from `ClaudeSession.init/1` to a dedicated `Destila.AI.PluginManager` module that runs once at boot. Cache `plugin_paths` in `:persistent_term`.

**Why:** Plugin state is global (filesystem), not per-session. Currently runs ~42 redundant plugin commands per workflow.

**Effort:** Small. **Risk:** Low.

---

## Tier 3 — Framework Improvements

### W1. Worktree preparation as a phase precondition; decouple title generation

**Core insight:** Setup is not a phase — it's two unrelated concerns bundled together:
1. **Worktree preparation** — infrastructure precondition, may need to re-run (remote/Docker)
2. **Title generation** — cosmetic fire-and-forget job

#### W1a. Title generation as fire-and-forget

**What:** Enqueue title generation directly on session creation. Remove from setup coordination. Delete all `title_gen` metadata — `workflow_sessions.title_generating` is sufficient.

**Effort:** Small. **Risk:** Low.

#### W1b. Worktree preparation as a re-runnable precondition

**What:** Engine checks worktree availability before each phase start. If unavailable, enqueues `PrepareWorkflowSession` and waits. Delete `Workflows.Setup` entirely. Remove all `repo_sync`/`worktree` metadata — worktree path lives on `ai_sessions.worktree_path`, availability checked live via `Git.worktree_exists?/1`.

**Effort:** Medium. **Risk:** Medium.

---

### W2. Framework-driven metadata export

**What:** Add `export_as` field to `Phase` struct. Framework auto-exports AI response as metadata when set. Remove `handle_response/3` callback.

**Effort:** Small. **Risk:** Low.

---

### W3. AI provider behaviour

**What:** Define `Destila.AI.Provider` behaviour. Make `ClaudeSession` implement it. Callers use configured provider.

**Effort:** Medium. **Risk:** Low.

---

### W4. Standardize Engine return types

**What:** All Engine public functions return `{:ok, updated_ws}`. Callers use returned value directly — no redundant `get_workflow_session!` calls.

**Effort:** Small (after F3). **Risk:** Low.

---

### W5. Session as a `gen_statem` process

**What:** Replace `Destila.Executions.Engine` with a `Destila.Sessions.SessionProcess` `gen_statem`. The process owns the complete state machine. All user interaction flows through it.

**States:** `:setup`, `{:phase, N, :preparing}`, `{:phase, N, :processing}`, `{:phase, N, :awaiting_input}`, `{:phase, N, :awaiting_confirmation}`, `:done`

**Interaction pattern:**
- User actions → synchronous calls returning `{:ok, ws}` (LiveView updates optimistically)
- Worker results → async casts (LiveView learns via PubSub)
- AI streaming → bypasses SessionProcess (display concern, not state)
- PubSub broadcasts `{:status_changed, ...}` and `{:message_added, ...}` for incremental LiveView updates

**What stays in LiveView:** rendering, question answer accumulation, title editing, streaming display. What moves to SessionProcess: all domain state transitions.

**Effort:** Large. **Risk:** Medium.

---

## Tier 4 — Real-time & UI

### U1. Centralized aliveness tracker

**What:** `Destila.AI.AlivenessTracker` GenServer with ETS table + PubSub. Remove per-LiveView `Process.monitor` logic (~50 lines).

**Effort:** Medium. **Risk:** Low.

---

### U2. SQL-level classification for the Crafting Board

**What:** Push session classification into database queries instead of Elixir. Requires F3.

**Effort:** Small. **Risk:** Low.

---

## Tier 5 — Hygiene

### H1. Explicit error on nil AI session

**What:** Log a warning when AI session is nil during phase_update, instead of silently returning `:awaiting_input`.

**Effort:** Trivial. **Risk:** Low.

---

### H2. Normalize atom/string keys at the stream boundary

**What:** Normalize keys to strings in `ClaudeSession` stream collector. Remove dual-key `access/2` helper.

**Effort:** Small. **Risk:** Low.

---

## Summary Matrix

| # | Description | Impact | Risk | Effort | Depends On |
|---|-------------|--------|------|--------|------------|
| **F1** | `Ecto.Enum` for `PhaseExecution.status` | High | Low | Small | — |
| **F2** | Explicit phase execution state machine | High | Low | Small | F1 |
| **F3** | Eliminate `phase_status` from `workflow_sessions` | High | Medium | Medium | F1, F2 |
| **F4** | Messages FK directly to `workflow_sessions` | Medium | Low | Small | — |
| **S1** | Extract `AI.ResponseProcessor` | High | Low | Small | — |
| **S3** | Move `session_opts_for_workflow` out of GenServer | Medium | Low | Small | — |
| **S4** | Plugin management at boot | High | Low | Small | — |
| **W1a** | Title generation as fire-and-forget | Medium | Low | Small | — |
| **W1b** | Worktree prep as phase precondition | High | Medium | Medium | F1, F2 |
| **W2** | Framework-driven metadata export | Medium | Low | Small | — |
| **W3** | AI provider behaviour | Medium | Low | Medium | S3 |
| **W4** | Standardize Engine return types | Medium | Low | Small | F3 |
| **W5** | Session as `gen_statem` process | High | Medium | Large | F1, F2, F3, W4, W1b |
| **U1** | Centralized aliveness tracker | Medium | Low | Medium | — |
| **U2** | SQL-level classification | Low | Low | Small | F3 |
| **H1** | Explicit error on nil AI session | Low | Low | Trivial | — |
| **H2** | Normalize keys at stream boundary | Low | Low | Small | — |

---

## Suggested Implementation Order

**Sequential chain:**

```
F1 (Ecto.Enum) -> F2 (state machine) -> F3 (eliminate dual state) -> W4 (Engine returns) -> W5 (gen_statem)
                                                                    -> U2 (SQL classification)
                                      -> W1b (worktree precondition) ─────────────────────/
```

**Independent track A:** `S1 (ResponseProcessor) + S4 (plugin boot) + H1 + H2`

**Independent track B:** `S3 (move session_opts) -> W3 (AI provider behaviour)`

**Independent track C:** `W1a (title fire-and-forget) + F4 (messages FK) + W2 (export_as) + U1 (aliveness tracker)`

**Starting point:** F1 + S1 + S4 + W1a in parallel.

### The sequential chain explained

- **F1** gives the state machine atoms to work with
- **F2** makes the state machine explicit and validated
- **F3** makes `phase_executions` the single source of truth
- **W1b** makes worktree prep a declarative precondition
- **W4** standardizes Engine returns — a clean interface for gen_statem replies
- **W5** is the payoff — the Engine becomes a `gen_statem` process

See `prompts.md` for detailed implementation prompts for each item.
