# Brainstorm: Self-Contained Workflow Architecture with Composable Phase Modules

**Date:** 2026-03-25
**Status:** Draft

## What We're Building

A refactored workflow system where workflow modules are fully self-contained. A workflow is an ordered list of reusable phase modules. Everything after selecting a workflow type — including what was previously the wizard and the setup hack — is a phase.

The primary deliverable is a single LiveView (`WorkflowRunnerLive`) that orchestrates phase transitions by mounting each phase's LiveComponent. Phase modules own their full execution: rendering, event handling, worker orchestration, and signaling completion.

### Concrete Example: Prompt for Chore / Task

| Phase | Module | UI | Creates |
|-------|--------|----|---------|
| 1 | WizardPhase | Form: project selection + initial idea | Workflow session (on completion) |
| 2 | SetupPhase | Task list: clone, worktree, title gen | Background workers |
| 3 | AiConversationPhase | Chat: task description | AI session, pushes user idea |
| 4 | AiConversationPhase | Chat: Gherkin review | Reuses AI session |
| 5 | AiConversationPhase | Chat: technical concerns | Reuses AI session |
| 6 | AiConversationPhase | Chat: prompt generation | Reuses AI session |

## Why This Approach

The current architecture spreads workflow concerns across many modules:
- **NewSessionLive** owns the wizard (project + idea collection)
- **Destila.Setup** coordinates Phase 0 with an atomic compare-and-swap hack
- **SessionDetailLive** renders chat + setup progress
- **Workflow modules** define phases but are orchestrated externally
- Phase 0 has special-case filtering, status handling, and message exclusion

This creates tight coupling, makes it hard to add new workflows, and requires understanding multiple modules to change any single workflow behavior.

The new model consolidates everything: one LiveView, composable phase modules, workflows as simple lists.

## Key Decisions

### 1. Single LiveView as the runner
All runner logic lives in `WorkflowRunnerLive`. No separate `WorkflowRunner` module. Phase transitions are `handle_event`/`handle_info` callbacks. Tested via LiveView integration tests.

### 2. Phases are LiveComponents
Each phase module provides a LiveComponent that handles its own rendering and events. The parent LiveView mounts the current phase's component. Three phase types exist but aren't declared explicitly — they're just different LiveComponents:
- **WizardPhase** — forms, collects data, signals completion synchronously
- **SetupPhase** — task list with progress, enqueues workers, signals completion via PubSub
- **AiConversationPhase** — chat UI, creates/resumes AI sessions, uses markers for phase advance

### 3. Session creation is workflow-defined
The workflow decides when the session is created. For `prompt_chore_task`, Phase 1 (Wizard) collects project + idea, then signals the LiveView to create the session. Before session creation, state is in-memory (LiveView assigns). After, it's in the DB. Other future workflows may create the session at a different point or immediately after workflow type selection.

### 4. AI session creation is phase-specific
For `prompt_chore_task`, the AI session (Claude Code connection) is created in Phase 3 (Task Description), not during Setup. Other workflows may create it at a different time or not at all. The Setup phase handles only git/worktree/title operations.

### 5. Static workflows deferred
`prompt_new_project` and `implement_generic_prompt` are removed for now. They'll return later as composable phase workflows. This narrows the refactor scope to `prompt_chore_task` only.

### 6. Crafting board unchanged
The crafting board (sectioned list + Group by Workflow toggle) stays as-is. The two removed workflows won't show boards until they return. Sessions only appear on the board after the workflow session DB record exists.

### 7. Phases start at 1, no Phase 0
No more 0-indexed special casing. The `phase_status: :setup` hack, `Destila.Setup.maybe_finish_phase0`, and phase-0 message filtering all go away.

### 8. Fresh DB start
Drop and recreate. No migration of existing session data.

### 9. Workflow = list of {PhaseModule, opts}
Each workflow module declares its phases as a simple list of `{PhaseModule, opts}` tuples. No DSL macros, no behaviour enforcement on the workflow module itself. Example:

```elixir
defmodule Destila.Workflows.PromptChoreTaskWorkflow do
  def phases do
    [
      {Destila.Phases.WizardPhase, fields: [:project, :idea]},
      {Destila.Phases.SetupPhase, steps: [:clone, :worktree, :title_gen]},
      {Destila.Phases.AiConversationPhase, name: "Task Description", system_prompt: &task_prompt/1},
      {Destila.Phases.AiConversationPhase, name: "Gherkin Review", system_prompt: &gherkin_prompt/1},
      {Destila.Phases.AiConversationPhase, name: "Technical Concerns", system_prompt: &technical_prompt/1},
      {Destila.Phases.AiConversationPhase, name: "Prompt Generation", system_prompt: &prompt_gen_prompt/1}
    ]
  end
end
```

### 10. Routing and session resume
WorkflowRunnerLive serves two URL patterns:
- **Pre-session:** `/workflows/:workflow_type` — no session ID yet. Phase 1 (Wizard) runs with in-memory state. On completion, the LiveView creates the session and `push_navigate`s to the post-session URL.
- **Post-session:** `/sessions/:id` — the LiveView loads the session, determines the current phase from DB state, and mounts the correct LiveComponent. This handles both forward progression and resume (e.g., user returns while setup is running in the background).

The crafting board and other pages link to `/sessions/:id`. The `/workflows/:workflow_type` URL is only used when starting a new workflow.

### 11. Terminology rename
- "Steps" at the workflow level become "phases"
- "Steps" now refer to sub-operations within a phase (wizard fields, setup tasks)
- DB columns `steps_completed`/`steps_total` become phase-based naming

## What Gets Deleted

- `Destila.Setup` — replaced by SetupPhase LiveComponent
- `DestilaWeb.NewSessionLive` — replaced by WizardPhase within WorkflowRunnerLive
- `DestilaWeb.SessionDetailLive` — replaced by WorkflowRunnerLive
- `Destila.Workflows.PromptNewProjectWorkflow` — deferred
- `Destila.Workflows.ImplementGenericPromptWorkflow` — deferred
- `features/create_session_wizard.feature` — replaced by wizard phase behavior in workflow features
- `features/phase_zero_setup.feature` — replaced by `setup_phase.feature`

## What Stays

- **Workers** (SetupWorker, TitleGenerationWorker, AiQueryWorker) — enqueued by phase modules instead of external orchestration
- **Destila.Workflows** dispatcher — updated to work with new phase list model
- **WorkflowSession schema** — updated columns (phase-based naming), same flat table
- **Messages context** — unchanged
- **PubSub broadcasts** — same pattern, phases subscribe/broadcast
- **Crafting board** — unchanged
- **Project management, session archiving, generated prompt viewing** — unchanged

## Gherkin Updates Needed

The provided Gherkin scenarios need these adjustments:
1. **chore_task_workflow.feature** — add Phase 1 (Wizard) for project + idea collection; renumber all phases (Setup becomes Phase 2, Task Description becomes Phase 3, etc.; total 6 phases not 5)
2. **setup_phase.feature** — remove "Starting AI session..." from setup steps (AI session moves to Phase 3)
3. **crafting_board.feature** — remove scenarios referencing "New Project" and "Generic Prompt" workflow types from examples (the feature stays, just fewer workflow types to test)

## Open Questions

*None remaining — all questions resolved during brainstorming.*

## Resolved Questions

1. **Where do project selection and initial idea live?** They become Phase 1 (WizardPhase) of the chore_task workflow. The session is created when this phase completes.
2. **How does the runner work pre-session?** Phase 1 is in-memory (LiveView assigns). The LiveView starts with just a workflow_type and no session ID. After wizard completion, session is created and subsequent phases are DB-driven.
3. **What happens to static workflows?** Deferred/removed for now. Focus on prompt_chore_task only.
4. **Where is the AI session created?** In Phase 3 (Task Description) for chore_task. Phase-specific, not a setup concern.
5. **How do phases render?** Each phase provides a LiveComponent. The parent LiveView mounts the current phase's component.
6. **Is there a separate WorkflowRunner module?** No. All runner logic lives in WorkflowRunnerLive (single LiveView).
