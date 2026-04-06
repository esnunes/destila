# Destila — Application Analysis & Refactoring Report

## Part 1: Functional Description

### What is Destila?

Destila is an AI-powered workflow orchestration platform for software development. It manages multi-phase workflows where each phase involves an AI conversation or autonomous execution to accomplish a specific goal.

### Core Concepts

**Projects** represent codebases. Each project has a name and at least one source location (git repo URL and/or local filesystem path). Projects provide context for AI execution.

**Workflow Types** are templates defining a sequence of phases. Two exist today:

- **Brainstorm Idea** (4 phases) — Refines a vague coding idea into a structured implementation prompt through guided AI conversation: (1) Task Description, (2) Gherkin Review, (3) Technical Concerns, (4) Prompt Generation.

- **Implement a Prompt** (7 phases) — Takes a prompt and executes end-to-end: (1) Generate Plan, (2) Deepen Plan, (3) Work, (4) Review, (5) Browser Tests, (6) Feature Video, (7) Adjustments.

**Sessions** are running instances of a workflow, each associated with a project.

**Phases** are either:

- **Interactive** — AI asks questions (structured: single-select, multi-select, multi-question forms; or free text). Advances when AI signals readiness and user confirms.
- **Non-interactive** — AI works autonomously. User can cancel or retry on failure.

### Session Lifecycle

1. **Creation** — User selects workflow type, provides input (idea text or an exported prompt from a prior session), selects a project
2. **Setup** — Parallel background tasks: title generation, git repository sync, git worktree creation
3. **Phase execution** — Sequential phases, each with its own AI conversation or autonomous work
4. **Completion** — User marks session as done
5. **Archival** — Sessions can be archived/restored

### Metadata & Chaining

Phases produce metadata (key-value pairs). Some metadata is "exported" — visible in a sidebar and available as input to future sessions. This enables chaining: a Brainstorm session exports its generated prompt, which can be selected as input for an Implement session.

### Views

- **Dashboard** — Overview with status counts and recent sessions
- **Crafting Board** — Active sessions in list view (grouped by status) or workflow view (kanban by phase). Filterable by project. Real-time AI aliveness indicators.
- **Workflow Runner** — Chat interface with phase navigation and collapsible metadata sidebar
- **Projects** — CRUD management (inline creation also available during session creation)
- **Archived Sessions** — Browse and restore archived sessions

---

## Part 2: Technical Design

Starting from the functional description alone, here is how this system should be designed.

### Domain Boundaries

| Context | Responsibility | Key Entities |
|---------|---------------|-------------|
| **Projects** | CRUD for codebases | `Project` |
| **Workflows** | Type definitions, session lifecycle, metadata | `Session`, `SessionMetadata`, `Phase` (struct), workflow behaviour modules |
| **Orchestration** | Phase state machine, transition logic, setup coordination | `PhaseExecution`, `Engine` |
| **AI** | Conversation management, message storage, response processing, session lifecycle | `AiSession`, `Message`, `ClaudeSession` (GenServer) |
| **Git** | Repository operations | (no entities — pure functions) |

### State Machines

**Session:** `created -> setup -> [phase_1 .. phase_N] -> done <-> archived`

**Phase Execution:**

```
pending -> processing -> awaiting_input <-> processing -> awaiting_confirmation -> completed
                      \-> failed                                                /
                      \-> skipped
```

### Key Design Principles

1. **Workflow modules are purely declarative** — phases, prompts, metadata; no orchestration
2. **Single orchestrator** (Engine) — owns all phase transition logic
3. **AI conversation is a service** — Engine delegates to it; it has no phase/workflow knowledge
4. **Single source of truth per state** — phase status in one place, session status in one place
5. **Return the updated state** — Engine functions return `{:ok, ws}` so callers don't re-fetch
6. **Response processing is a separate concern** — transform raw AI responses in a dedicated module, not the data access layer

---

## Part 2b: Greenfield Design

If building from scratch — same requirements, blank codebase — the key architectural differences would be:

1. **Session as `gen_statem` process** — Each session is a process that owns its state machine, not a DB row coordinated by multiple modules
2. **No dual state** — Phase execution status is the single source of truth; no redundant field on the session
3. **Setup as Phase 0** — No special-case setup logic (later revised: worktree prep as a re-runnable precondition instead)
4. **Messages FK directly to sessions** — No join through ai_sessions for queries
5. **Separate infrastructure state from domain metadata** — (later revised: eliminate infrastructure metadata entirely)
6. **Domain events table** — Append-only audit log for debugging and replay
7. **AI provider abstraction** — Behaviour for AI providers, decoupled from ClaudeCode
8. **Phase as behaviour** — Per-phase modules instead of structs with function references
9. **Centralized aliveness tracker** — ETS + PubSub replaces per-LiveView process monitoring
10. **SQL-level classification** — Push board grouping into queries, not Elixir

See `report2.md` for the complete refactoring plan that bridges from the current implementation to this architecture.
