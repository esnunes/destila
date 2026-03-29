# Institutional Knowledge: Workflow Architecture & Phase Transitions

**Date:** 2026-03-28  
**Sources:** Plan docs from workflow refactoring (2026-03-25, 2026-03-27), brainstorms, and chore task workflow implementation (2026-03-20)

## Critical Architecture Pattern: Self-Contained LiveComponent Phases

This project uses a pattern where workflows are orchestrated by a single `WorkflowRunnerLive` LiveView that mounts phase-specific LiveComponents. This is a CRITICAL pattern to understand before implementing any new workflow or modifying phases.

### The Core Pattern

```
WorkflowRunnerLive (parent LiveView)
  ├─ Subscribes to PubSub for phase-level transitions only
  ├─ Maintains @phase_data map (accumulates output from completed phases)
  └─ Mounts current phase's LiveComponent
      ├─ WizardPhase (form input, in-memory state)
      ├─ SetupPhase (task list, enqueues workers)
      └─ AiConversationPhase (chat, creates/resumes AI sessions)

Each phase component:
  ├─ Subscribes to PubSub directly (handle_info/2)
  ├─ Handles its own real-time updates
  └─ Signals completion to parent via send(self(), {:phase_complete, phase, data})
```

**Key Design Decisions:**
1. **Parent does NOT forward PubSub to components.** Each component subscribes and handles its own updates.
2. **Self() in a LiveComponent returns the parent LiveView's PID.** This is how components signal the parent.
3. **Phase data flows via @phase_data map.** Parent accumulates output from completed phases and passes to next phase component as assign.
4. **Components are TRULY self-contained.** They handle their own rendering, events, worker orchestration, and PubSub.

### Phase Communication Protocol

```elixir
# Parent → Component
assigns: (workflow_session, opts, phase_number, phase_data)

# Component → Parent  
send(self(), {:phase_complete, phase, data})
send(self(), {:phase_event, event, data})

# PubSub → Component (direct subscription)
handle_info({:message_added, msg})
handle_info({:workflow_session_updated, ws})

# PubSub → Parent (phase transitions only)
handle_info({:workflow_session_updated, ws})  # watches for current_phase changes
```

## Schema Design for Workflows with Phases

The refactored schema separates concerns across multiple tables:

### workflow_sessions table
- `current_phase :integer` (was `steps_completed`)
- `total_phases :integer` (was `steps_total`)
- `phase_status :enum` (`:setup`, `:generating`, `:conversing`, `:advance_suggested`)
- `setup_steps :map` (tracks setup task progress as JSON, e.g., `%{"clone" => "completed", "worktree" => "in_progress"}`)
- `title :string` (editable after session creation)
- `workflow_type :enum` (`:prompt_chore_task`, others added later)
- `column :enum` (`:distill`, `:done` — no `:request` anymore)
- `archived_at :utc_datetime` (for soft deletes)
- `project_id :binary_id` (FK to projects)

**Critical change:** Removed `ai_session_id` and `worktree_path` from this table (moved to ai_sessions).

### ai_sessions table (NEW)
- `id :binary_id` (primary key)
- `workflow_session_id :binary_id` (FK to workflow_sessions)
- `claude_session_id :string` (the session identifier for AI resume)
- `worktree_path :string` (where repo is cloned)
- `timestamps`

**Why?** The AI session is phase-specific (created in Phase 3 of chore_task). Multiple AI sessions can exist for a single workflow session if a workflow has multiple AI phases. This allows independent session management and resume capability.

### messages table
- `ai_session_id :binary_id` (FK, was `workflow_session_id`)
- `role :enum` (`:system`, `:user`)
- `content :string` (the message text)
- `raw_response :map` (full AI response for read-time derivation)
- `selected [:array, :string]` (user selections from AI-suggested options)
- `phase :integer` (which phase this message belongs to)
- `inserted_at :utc_datetime_usec`

**Critical change:** Messages now belong to `ai_sessions`, not `workflow_sessions`. This enables proper scoping when multiple AI sessions exist.

## Phase Types & Contracts

### WizardPhase
- **Purpose:** Collect user input in a form (project selection, initial idea, etc.)
- **State:** In-memory (LiveView assigns)
- **Signal completion:** Synchronously send `{:phase_complete, 1, %{project_id: "...", idea: "..."}}`
- **Parent action on completion:** Create workflow_session DB record, `push_navigate` to post-session URL
- **Example:** `prompt_chore_task` Phase 1 collects project + idea

### SetupPhase
- **Purpose:** Execute setup tasks (clone, worktree, title generation) via background workers
- **State:** DB-driven (reads from `workflow_sessions.setup_steps` JSON)
- **Signal completion:** Workers call `SetupCoordinator.maybe_advance_setup/1` which atomically advances `current_phase` when all steps done
- **Component behavior:** Renders task list, subscribes to `:workflow_session_updated`, detects phase advance, signals parent
- **Parent action on completion:** Mount next phase component
- **Example:** `prompt_chore_task` Phase 2 runs clone, worktree, title_gen workers

### AiConversationPhase
- **Purpose:** Have a multi-turn conversation with AI for context gathering or generation
- **State:** Persisted in ai_sessions + messages; AI session GenServer maintains runtime state
- **Configuration via opts:**
  - `name :string` — display name
  - `system_prompt :fun/1` — function that takes workflow_session and returns system prompt
  - `skippable :boolean` — whether phase can auto-advance via `<<SKIP_PHASE>>` (now `session` tool)
  - `final :boolean` — true for last phase; shows "Mark as Done" instead of "Ready to Advance"
- **First AI phase (Phase 3):** Creates AI session via `AI.Session.for_workflow_session/2`
- **Subsequent phases:** Resumes existing AI session, sends system prompt as new query
- **Signal completion:** User clicks "Continue to Phase N" (after AI suggests) or "Mark as Done" (if final)
- **Example:** `prompt_chore_task` Phases 3-6 are all AiConversationPhase instances with different system prompts

## Critical Workflow Definition Pattern

Workflows are defined as a simple list of `{PhaseModule, opts}` tuples in a function:

```elixir
defmodule Destila.Workflows.PromptChoreTaskWorkflow do
  def phases do
    [
      {DestilaWeb.Phases.WizardPhase, name: "Project & Idea", fields: [:project, :idea]},
      {DestilaWeb.Phases.SetupPhase, name: "Setup"},
      {DestilaWeb.Phases.AiConversationPhase, 
       name: "Task Description", system_prompt: &task_prompt/1},
      {DestilaWeb.Phases.AiConversationPhase, 
       name: "Gherkin Review", system_prompt: &gherkin_prompt/1, skippable: true},
      {DestilaWeb.Phases.AiConversationPhase, 
       name: "Technical Concerns", system_prompt: &technical_prompt/1},
      {DestilaWeb.Phases.AiConversationPhase, 
       name: "Prompt Generation", system_prompt: &prompt_gen_prompt/1, final: true}
    ]
  end
  
  def total_phases, do: length(phases())
  def phase_name(phase_num), do: Enum.at(phases(), phase_num - 1) |> elem(1) |> Map.get(:name)
  def default_title, do: "New Chore/Task"
  
  # System prompts
  defp task_prompt(workflow_session), do: "..."
  defp gherkin_prompt(workflow_session), do: "..."
  # etc.
end
```

**No DSL macros, no behavior enforcement.** Just a simple list. `WorkflowRunnerLive` queries the workflow module for the phases list and mounts them in order.

## PubSub Subscription Pattern

**Parent (WorkflowRunnerLive):**
```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    PubSub.subscribe(Destila.PubSub, "store:updates")
  end
  ...
end

def handle_info({:workflow_session_updated, %{id: id} = ws}, socket) do
  # Check if current_phase changed
  if ws.current_phase != socket.assigns.workflow_session.current_phase do
    # Remount the correct phase component
    {:noreply, assign(socket, :workflow_session, ws) |> mount_current_phase()}
  else
    {:noreply, assign(socket, :workflow_session, ws)}
  end
end
```

**Components (each phase):**
```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    PubSub.subscribe(Destila.PubSub, "store:updates")
  end
  ...
end

def handle_info({:message_added, msg}, socket) do
  # Component handles its own message updates
  {:noreply, stream(socket, :messages, [msg])}
end
```

## Phase Transition Mechanisms

### Wizard Phase Completion (Synchronous)
Component signals parent immediately after form submission:
```elixir
# In WizardPhase event handler
send(self(), {:phase_complete, 1, %{project_id: project_id, idea: idea}})
```

### Setup Phase Completion (Async via Worker Coordination)
Workers call coordinator after completing:
```elixir
# In worker after task completes
SetupCoordinator.maybe_advance_setup(workflow_session_id)
  # → Atomic CAS updates current_phase = 3 if all setup steps done
  # → Broadcasts :workflow_session_updated
  # → Parent detects change, remounts AiConversationPhase
```

### AI Phase Completion (User Confirmation or Auto-advance)
User clicks button or AI signals via tool:
```elixir
# Old mechanism (text markers): AI response ends with <<READY_TO_ADVANCE>>
# New mechanism (session tool): AI calls session tool with action: "suggest_phase_complete"

# In AiConversationPhase event handler on user click
send(self(), {:phase_complete, phase_num, %{}})
```

## Critical Gotchas & Learnings

### 1. Session Creation Timing Matters
**Gotcha:** If you create the session in the wrong phase, field references break.

**Pattern:** For `prompt_chore_task`, the session is created AFTER WizardPhase completes, not before. This allows Phase 1 to be fully in-memory and avoids DB writes until the user confirms their idea. If a new workflow needs the session created at a different point, it changes where the phase data flows.

**Mitigation:** Document when the session is created in your workflow definition. Make it explicit in the phase list comments.

### 2. AI Session Belongs to workflow_session, Not to Phase
**Gotcha:** You might think "each phase gets an AI session" but actually "each workflow session has AI sessions created on demand."

**Pattern:** The first AiConversationPhase creates the AI session. Subsequent AiConversationPhases in the same workflow reuse it. This allows context to carry across phases.

**Mitigation:** If a new workflow needs to start a fresh AI session for a later phase, create a new ai_sessions record. The contract allows multiple ai_sessions per workflow_session.

### 3. Phase Data Accumulation is Unidirectional
**Gotcha:** If Phase 2 needs output from Phase 4, you have to go through the DB. In-memory phase_data only flows forward.

**Pattern:** Phase 1 → Phase_data stores project_id + idea. Phase 2 receives it as assign. Phase 3 receives it as assign. Phase 4 cannot access Phase 3's output via phase_data; it must query messages.

**Mitigation:** If later phases need data from earlier ones, ensure the data is persisted to the DB during those earlier phases.

### 4. The Setup Coordination Pattern is Complex
**Gotcha:** SetupPhase runs multiple workers in parallel. You must ensure they all finish before Phase 3 starts.

**Pattern:** Each worker calls `SetupCoordinator.maybe_advance_setup/1` after completing. The coordinator reads `setup_steps` JSON, checks all required steps have status "completed", then atomically advances `current_phase` if all done. Only the FIRST coordinator call that sees all steps complete wins; subsequent calls no-op.

**Mitigation:** 
- Document which workers call the coordinator in your workflow
- Add a helper to check all steps are done: `SetupCoordinator.all_steps_done?/1`
- Test that concurrent worker completion doesn't cause races

### 5. Remove the LiveComponent Restriction
**Gotcha:** The old CLAUDE.md said "No LiveComponents unless strongly needed." This architecture REQUIRES LiveComponents.

**Pattern:** Update CLAUDE.md after implementing the refactor. LiveComponents are the pattern for phases.

**Mitigation:** Document the WorkflowRunnerLive + phase component pattern in CLAUDE.md.

### 6. URL Routing Changes
**Gotcha:** There are now TWO URLs for workflows:
- `/workflows/:workflow_type` — pre-session (Phase 1 wizard)
- `/sessions/:id` — post-session (Phases 2+)

**Pattern:** Crafting board links to `/sessions/:id`. New workflow links to `/workflows/:workflow_type`. On wizard completion, the LiveView `push_navigate`s to `/sessions/:id` with the newly created session.

**Mitigation:** Ensure both routes exist in router. Test that the wizard→session redirect works.

## Terminology Updates

Old → New:
- "Steps" (at workflow level) → "Phases" (now specifically workflow phases)
- "Steps" (sub-operations) → Stays as "steps" (e.g., setup steps, wizard fields)
- `steps_completed` → `current_phase`
- `steps_total` → `total_phases`
- Text markers (`<<READY_TO_ADVANCE>>`, `<<SKIP_PHASE>>`) → `session` MCP tool with actions

## Testing Strategy for Phase Architecture

### Test Files Structure
- `test/destila_web/live/workflow_runner_live_test.exs` — parent orchestration
- `test/destila_web/live/phases/wizard_phase_test.exs` — phase 1 input
- `test/destila_web/live/phases/setup_phase_test.exs` — phase 2 workers + coordination
- `test/destila_web/live/phases/ai_conversation_phase_test.exs` — phase 3+ AI conversation
- Feature files: `features/chore_task_workflow.feature`, `features/setup_phase.feature`, etc.

### Key Testing Patterns
1. **Phase completion signals** — assert `send/2` calls are made correctly
2. **Phase data accumulation** — verify each phase receives correct phase_data assign
3. **PubSub message handling** — mock PubSub events, verify component updates
4. **Phase remounting** — verify parent remounts correct phase on `current_phase` change
5. **Setup coordination** — test concurrent worker completion and atomic CAS

## When Adding a New Workflow

1. **Create workflow module** with `phases/0` function defining phase list
2. **Create phase components** for each custom phase type (if not reusing existing phases)
3. **Add routing** in router.ex for `/workflows/:workflow_type` and `/sessions/:id`
4. **Update WorkflowRunnerLive** to handle the new workflow_type (if it needs special behavior)
5. **Define system prompts** in workflow module (for AiConversationPhase workflows)
6. **Add feature file** describing workflow scenarios
7. **Test phase transitions, data flow, and PubSub messaging**

## When Modifying Phase Behavior

1. **Update phase component** (LiveComponent)
2. **Update workflow module** if opts change (for AiConversationPhase)
3. **Update tests** for the component
4. **Update feature file** if behavior changes
5. **Broadcast PubSub events** if the phase now affects other parts of the system
6. **Run full test suite** to catch downstream effects

## Database Considerations

- Fresh DB only — no migration path for existing data
- `setup_steps` JSON can be extended with new step types without schema changes
- `phase_status` enum can be extended with new statuses
- Multiple ai_sessions per workflow_session is supported but rare
- Messages can be queried by ai_session_id (direct FK) or by workflow_session_id (via ai_sessions join)
