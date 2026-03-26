---
title: "Refactor: Self-Contained Workflow Architecture with Composable Phase Modules"
type: refactor
date: 2026-03-25
brainstorm: docs/brainstorms/2026-03-25-workflow-phase-architecture-brainstorm.md
---

# Refactor: Self-Contained Workflow Architecture with Composable Phase Modules

## Overview

Refactor Destila's workflow system so that workflow modules are fully self-contained.
A workflow is an ordered list of reusable phase LiveComponents. A single LiveView
(`WorkflowRunnerLive`) orchestrates phase transitions, handles PubSub, and mounts
the current phase's component.

This replaces `NewSessionLive`, `SessionDetailLive`, and `Destila.Setup` with a
unified architecture. Static workflows (`prompt_new_project`, `implement_generic_prompt`)
are removed for now — the refactor focuses on `prompt_chore_task` only.

### Prompt for Chore / Task — Phase Layout

| Phase | Module | UI | Key Action |
|-------|--------|----|------------|
| 1 | WizardPhase | Form: project + idea | Creates workflow session on completion |
| 2 | SetupPhase | Task list: clone, worktree, title | Enqueues background workers |
| 3 | AiConversationPhase | Chat: Task Description | Creates AI session, pushes idea |
| 4 | AiConversationPhase | Chat: Gherkin Review | Skippable via `<<SKIP_PHASE>>` |
| 5 | AiConversationPhase | Chat: Technical Concerns | |
| 6 | AiConversationPhase | Chat: Prompt Generation | Mark as Done, prompt card |

## Problem Statement

The current architecture spreads workflow concerns across many modules:
- `NewSessionLive` — wizard (project + idea collection)
- `Destila.Setup` — Phase 0 coordination with atomic CAS hack
- `SessionDetailLive` (834 lines) — chat, setup progress, phase transitions, archiving
- Workflow modules define phases but are orchestrated externally
- Phase 0 has special-case filtering, status handling, message exclusion

Adding a new workflow or changing phase behavior requires touching 4+ modules.

## Proposed Solution

### Architecture

```
                        WorkflowRunnerLive
                        (PubSub subscriber, phase orchestrator)
                               |
                    ┌──────────┼──────────────┐
                    |          |              |
              WizardPhase  SetupPhase  AiConversationPhase
              (LiveComp)   (LiveComp)     (LiveComp)
                    |          |              |
              [in-memory]  [Oban workers]  [AI.Session + AiQueryWorker]
```

**Key architectural decisions:**
1. **Components handle their own PubSub.** Recent Phoenix LiveView versions allow LiveComponents to implement `handle_info/2`. Each phase component subscribes to `"store:updates"` and handles its own real-time updates (e.g., SetupPhase tracks worker progress, AiConversationPhase receives new messages). This makes phases truly self-contained.
2. **Parent handles phase-level orchestration only.** WorkflowRunnerLive subscribes to PubSub for phase transitions (detecting `current_phase` changes) and manages shared chrome (title, progress bar, archive). It does NOT forward PubSub events to components.
3. **Components signal parent via `send/2`.** Phase components use `send(self(), {:phase_complete, phase, data})` to tell the parent they're done. `self()` in a LiveComponent returns the parent LiveView's PID.
4. **Session creation is workflow-defined.** No DB record during Phase 1 (Wizard). Session created when wizard completes.
5. **Setup coordination stays worker-side.** Workers call a coordination function after completing. Atomic CAS advances `current_phase`. Components and LiveView pick up the change via PubSub (or on mount if user was away).

### Routing

Two URL patterns served by `WorkflowRunnerLive`:
- `/workflows/:workflow_type` — pre-session (Phase 1 wizard, in-memory state)
- `/sessions/:id` — post-session (Phases 2+, DB-driven)

On wizard completion: `push_navigate` to `/sessions/:id`.

### Schema Changes (fresh DB)

**Three key changes:** rename phase columns, extract AI session fields into `ai_sessions` table,
link messages to `ai_sessions` instead of `workflow_sessions`.

```
workflow_sessions
├── id :binary_id
├── title :string
├── workflow_type :enum [:prompt_chore_task]
├── column :enum [:distill, :done]
├── current_phase :integer, default: 1       # renamed from steps_completed
├── total_phases :integer                     # renamed from steps_total
├── phase_status :enum [:setup, :generating, :conversing, :advance_suggested]
├── title_generating :boolean
├── setup_steps :map, default: %{}            # NEW: tracks setup progress as JSON
├── position :integer
├── archived_at :utc_datetime
├── project_id :binary_id (FK)
├── timestamps

ai_sessions                                    # NEW TABLE
├── id :binary_id
├── workflow_session_id :binary_id (FK)
├── claude_session_id :string                  # renamed from ai_session_id
├── worktree_path :string                      # moved from workflow_sessions
├── timestamps

messages
├── id :binary_id
├── ai_session_id :binary_id (FK)              # changed: was workflow_session_id
├── role :enum [:system, :user]
├── content :string
├── raw_response :map
├── selected {:array, :string}
├── phase :integer, default: 1
├── inserted_at :utc_datetime_usec
```

**Key changes:**
- `ai_session_id` and `worktree_path` move from `workflow_sessions` to `ai_sessions`
- `ai_sessions.claude_session_id` stores the Claude Code session identifier (for resume)
- Messages belong to `ai_sessions` (not `workflow_sessions`)
- Setup progress moves from messages to a `setup_steps` JSON map on `workflow_sessions`
  (e.g., `%{"title_gen" => "completed", "repo_sync" => "in_progress", "worktree" => "failed"}`)
- Title generation uses `Destila.AI.generate_title/2` (one-off query, no persistent session)
- Remove `:prompt_new_project`, `:implement_generic_prompt` from `workflow_type` enum
- Remove `:request` from `column` enum (wizard is pre-session)

### WorkflowRunnerLive — Responsibilities

**Shared chrome (always rendered):**
- Back link (to crafting board)
- Workflow type badge
- Phase progress bar: "Phase X/Y — Phase Name"
- Title (editable after session creation)
- Archive button (after session creation)

**Phase orchestration:**
- Maintains `@phase_data` map — accumulates output from completed phases, passed to current component
- On mount at `/workflows/:type`: determine workflow phases, init `@phase_data = %{}`, mount Phase 1
- On mount at `/sessions/:id`: load session from DB, reconstruct `@phase_data` from DB state (project_id, idea from messages), determine `current_phase`, mount correct component
- On `{:phase_complete, phase, data}`: merge `data` into `@phase_data`, advance to next phase
  - If wizard: create session, `push_navigate` to `/sessions/:id`
  - If setup/AI: update `current_phase` in DB, mount next component with updated `phase_data`
- On PubSub `:workflow_session_updated`: check if `current_phase` changed, remount if needed

**PubSub handling (parent — phase transitions only):**
- Subscribes to `"store:updates"` on `connected?`
- Handles `:workflow_session_updated` — checks if `current_phase` changed; if so, remounts the correct phase component
- Does NOT handle `:message_added` — each component handles its own messages
- Refreshes `workflow_session` from DB on relevant events (for title/progress bar updates)

### Phase Communication Protocol

```
Parent → Component:  assigns (workflow_session, opts, phase_number, phase_data)
Component → Parent:  send(self(), {:phase_complete, phase, data})
                     send(self(), {:phase_event, event, data})
PubSub → Component:  handle_info({:message_added, msg})         # component subscribes directly
                     handle_info({:workflow_session_updated, ws}) # component subscribes directly
PubSub → Parent:     handle_info({:workflow_session_updated, ws}) # parent watches for phase changes
```

Each phase component subscribes to `"store:updates"` in its `mount/1` and handles
its own real-time updates. The parent also subscribes to detect phase-level transitions
(e.g., `current_phase` changed by a worker) and remounts the correct component.

**Cross-phase data flow:** The parent maintains a `@phase_data` map that accumulates
output from completed phases. When a phase sends `{:phase_complete, phase, data}`,
the parent merges `data` into `@phase_data` and passes it as an assign to the next
phase component. This allows phases to consume data produced by earlier phases.

Example flow for chore_task:
1. WizardPhase completes → sends `{:phase_complete, 1, %{project_id: "...", idea: "..."}}`
2. Parent stores `@phase_data = %{project_id: "...", idea: "..."}`, creates session
3. SetupPhase receives `phase_data` assign → uses `project_id` to know what to clone
4. AiConversationPhase (Phase 3) receives `phase_data` assign → uses `idea` to build initial AI query

After session creation, most data is also persisted in the DB (project_id on the
session, idea as a Phase 1 message). But `phase_data` provides a direct in-memory
channel that avoids redundant DB reads and works for pre-session phases.

### PromptChoreTaskWorkflow — New Structure

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

  def phase_name(phase), do: ...   # derived from phases() list
  def total_phases, do: length(phases())
  def default_title, do: "New Chore/Task"
  def completion_message, do: "..."

  # System prompts (moved from current module, unchanged)
  defp task_prompt(workflow_session), do: ...
  defp gherkin_prompt(workflow_session), do: ...
  defp technical_prompt(workflow_session), do: ...
  defp prompt_gen_prompt(workflow_session), do: ...
end
```

### AiConversationPhase — Opts Contract

| Opt | Type | Default | Description |
|-----|------|---------|-------------|
| `name` | string | required | Phase display name |
| `system_prompt` | fun/1 | required | `fn workflow_session -> string` |
| `skippable` | boolean | `false` | Phase supports `<<SKIP_PHASE>>` marker |
| `final` | boolean | `false` | Shows "Mark as Done" instead of advance; renders prompt card |

**Behavior by opts:**
- First AI phase (Phase 3): creates AI session via `AI.Session.for_workflow_session/2`, sends initial query with system prompt + user idea
- Subsequent phases: resumes existing AI session, sends system prompt as new query
- `skippable: true`: `<<SKIP_PHASE>>` triggers auto-advance (AiQueryWorker handles this)
- `final: true`: no `<<READY_TO_ADVANCE>>` handling; shows "Mark as Done" button; last AI message renders as prompt card with copy/markdown toggle

### Setup Coordination (replaces Destila.Setup)

The coordination problem: TitleGenerationWorker and SetupWorker run in parallel.
Both must finish before Phase 3 can begin.

**New approach — same pattern, new location:**

```elixir
defmodule Destila.Workflows.SetupCoordinator do
  @doc """
  Called by each setup worker after completing. Uses atomic CAS to
  advance current_phase when all steps are done.
  """
  def maybe_advance_setup(workflow_session_id) do
    # 1. Read setup_steps JSON from workflow_session
    # 2. Check all required steps have status: "completed"
    # 3. Atomic CAS: UPDATE workflow_sessions
    #    SET current_phase = 3, phase_status = NULL
    #    WHERE id = ? AND current_phase = 2 AND phase_status = :setup
    # 4. If CAS succeeds → broadcast :workflow_session_updated
    # 5. LiveView picks up the change, mounts AiConversationPhase
  end
end
```

**Why not LiveView-side coordination?** If the user navigates away during setup,
the LiveView is not connected. Workers must be able to advance the phase independently.
When the user returns, mount reads the DB and sees `current_phase: 3`.

**Phase 3 initialization on mount:** AiConversationPhase checks if any Phase 3
messages exist. If not, it creates the AI session and enqueues `AiQueryWorker`
with the system prompt + user idea (stored in Phase 1 messages).

## Technical Considerations

### What Gets Deleted
- `lib/destila/setup.ex` — replaced by `SetupCoordinator`
- `lib/destila_web/live/new_session_live.ex` — replaced by WizardPhase
- `lib/destila_web/live/session_detail_live.ex` — replaced by WorkflowRunnerLive
- `lib/destila/workflows/prompt_new_project_workflow.ex` — deferred
- `lib/destila/workflows/implement_generic_prompt_workflow.ex` — deferred
- `features/create_session_wizard.feature` — replaced
- `features/phase_zero_setup.feature` — replaced
- `test/destila_web/live/new_session_live_test.exs`
- `test/destila_web/live/session_detail_live_test.exs`

### What Gets Modified
- `lib/destila/workflows.ex` — dispatcher updated for new phase list API
- `lib/destila/workflows/prompt_chore_task_workflow.ex` — new `phases/0` structure
- `lib/destila/workflow_sessions/workflow_session.ex` — remove `ai_session_id`/`worktree_path`, add `setup_steps`, rename columns
- `lib/destila/workflow_sessions.ex` — context updated for new column names
- `lib/destila/messages/message.ex` — FK changes from `workflow_session_id` to `ai_session_id`
- `lib/destila/messages.ex` — queries via `ai_session_id`, helper for listing by workflow session
- `lib/destila/ai/session.ex` — GenServer uses `AiSession` record, registry key changes
- `lib/destila_web/router.ex` — new route for `/workflows/:workflow_type`
- `lib/destila/workers/setup_worker.ex` — calls `SetupCoordinator`, updates `setup_steps` JSON
- `lib/destila/workers/title_generation_worker.ex` — calls `SetupCoordinator`, updates `setup_steps`
- `lib/destila/workers/ai_query_worker.ex` — updated phase references, uses `ai_session_id`
- `lib/destila_web/live/crafting_board_live.ex` — updated classify/bucketing logic
- `lib/destila_web/components/board_components.ex` — updated phase label
- `CLAUDE.md` — remove LiveComponent restriction
- `assets/css/app.css` — phase divider styles

### What Gets Created
- `lib/destila_web/live/workflow_runner_live.ex` — main orchestrator LiveView
- `lib/destila_web/live/phases/wizard_phase.ex` — LiveComponent
- `lib/destila_web/live/phases/setup_phase.ex` — LiveComponent
- `lib/destila_web/live/phases/ai_conversation_phase.ex` — LiveComponent
- `lib/destila/workflows/setup_coordinator.ex` — replaces Destila.Setup
- `lib/destila/ai_sessions.ex` — AiSessions context
- `lib/destila/ai_sessions/ai_session.ex` — AiSession schema
- `features/setup_phase.feature` — new
- `features/chore_task_workflow.feature` — rewritten
- `features/crafting_board.feature` — updated
- Test files for new modules

### What Stays Unchanged
- `lib/destila/ai.ex`, `lib/destila/ai/tools.ex`
- `lib/destila/projects.ex`, `lib/destila/projects/`
- `lib/destila_web/components/chat_components.ex` (reused as-is)
- `lib/destila_web/components/core_components.ex`
- `lib/destila_web/live/projects_live.ex`
- `lib/destila_web/live/archived_sessions_live.ex`
- `lib/destila_web/live/dashboard_live.ex`
- `features/generated_prompt_viewing.feature`
- `features/project_inline_creation.feature`
- `features/project_management.feature`
- `features/session_archiving.feature`

## Implementation Phases

### Phase 1: Foundation (Schema, Routing, Workflow Module)

**Goal:** Fresh DB, new schema, routing, workflow module restructured, CLAUDE.md updated.

**Tasks:**

1. Update CLAUDE.md — remove LiveComponent restriction, note phase architecture
2. Create fresh migration:
   - `workflow_sessions`: rename `steps_completed` → `current_phase`, `steps_total` → `total_phases`
   - `workflow_sessions`: remove `ai_session_id`, `worktree_path` columns
   - `workflow_sessions`: add `setup_steps` map column (default `%{}`)
   - Remove `:request` from `column` enum
   - Remove `:prompt_new_project`, `:implement_generic_prompt` from `workflow_type` enum
   - Create `ai_sessions` table: `id`, `workflow_session_id` (FK), `claude_session_id`, `worktree_path`, timestamps
   - Update `messages` table: replace `workflow_session_id` FK with `ai_session_id` FK
3. Create `AiSession` schema (`lib/destila/ai_sessions/ai_session.ex`):
   - `belongs_to :workflow_session`
   - `has_many :messages`
   - Fields: `claude_session_id`, `worktree_path`
4. Create `AiSessions` context (`lib/destila/ai_sessions.ex`):
   - CRUD for ai_sessions
   - `get_or_create_for_workflow_session/2`
5. Update `WorkflowSession` schema:
   - Remove `ai_session_id`, `worktree_path` fields
   - Add `setup_steps` field
   - Add `has_many :ai_sessions`
   - Rename `steps_completed` → `current_phase`, `steps_total` → `total_phases`
6. Update `Message` schema:
   - Replace `workflow_session_id` with `ai_session_id` FK
7. Update `Messages` context:
   - All queries now go through `ai_session_id`
   - Add helper to list messages for a workflow session (via ai_sessions join)
8. Update `WorkflowSessions` context (all references to old column names)
9. Update `AI.Session` GenServer:
   - Registry key changes to `ai_session_id` (not `workflow_session_id`)
   - `for_workflow_session/2` creates/finds an `AiSession` record, then starts GenServer
   - Session opts read `worktree_path` from `AiSession` record
5. Update `Destila.Workflows` dispatcher for new `phases/0` API
6. Restructure `PromptChoreTaskWorkflow`:
   - Replace `steps/0` with `phases/0` (list of `{Module, opts}` tuples)
   - Replace `total_steps/0` with `total_phases/0`
   - Keep `phase_name/1`, `system_prompt/2`, `session_strategy/1`, `build_conversation_context/1`
   - Update `@phase_names` map for 6-phase numbering
   - Add `default_title/0`, `completion_message/0`
7. Delete `PromptNewProjectWorkflow` and `ImplementGenericPromptWorkflow`
8. Add routes to router:
   - `live "/workflows/:workflow_type", WorkflowRunnerLive` (pre-session)
   - `live "/sessions/:id", WorkflowRunnerLive` (post-session, replaces SessionDetailLive route)
   - Remove `live "/sessions/new", NewSessionLive`
9. Create `WorkflowRunnerLive` skeleton:
   - Two mount paths (workflow_type vs session ID)
   - Shared chrome rendering (back link, progress bar, title, archive)
   - Phase component mounting via `live_component`
   - PubSub subscription
   - `handle_info` for `:phase_complete` and PubSub events
10. Run `mix ecto.reset` and verify app starts

**Acceptance criteria:**
- [ ] App compiles and starts with new schema
- [ ] `/workflows/prompt_chore_task` renders WorkflowRunnerLive with progress bar
- [ ] `/sessions/:id` renders WorkflowRunnerLive (placeholder content)
- [ ] Old routes (`/sessions/new`) removed
- [ ] `mix precommit` passes

### Phase 2: WizardPhase LiveComponent

**Goal:** Phase 1 of chore_task workflow works end-to-end. User selects project, enters idea, session is created.

**Tasks:**

1. Create `lib/destila_web/live/phases/wizard_phase.ex`:
   - LiveComponent with `update/2` receiving `opts`, `projects` list
   - Port project selection UI from `NewSessionLive` (project list, create inline, skip)
   - Port initial idea textarea from `NewSessionLive`
   - Combined form: project at top, idea below, "Start" button
   - On submit: `send(self(), {:phase_complete, 1, %{project_id: ..., idea: ...}})`
2. Update `WorkflowRunnerLive` to handle wizard completion:
   - Create workflow session in DB with default title, `current_phase: 2`, `phase_status: :setup`, `column: :distill`
   - Create Phase 1 system message (the question) and user message (the idea) — same as current
   - Enqueue TitleGenerationWorker and SetupWorker
   - `push_navigate` to `/sessions/:id`
3. Update Gherkin feature files:
   - Create/update `features/chore_task_workflow.feature` with Phase 1 wizard scenarios
4. Write LiveView integration tests covering:
   - Rendering wizard on `/workflows/prompt_chore_task`
   - Project selection
   - Inline project creation
   - Idea submission → session creation → redirect

**Acceptance criteria:**
- [ ] User can navigate to `/workflows/prompt_chore_task` and see project + idea form
- [ ] Selecting a project and entering an idea creates a workflow session
- [ ] User is redirected to `/sessions/:id` after submission
- [ ] TitleGenerationWorker and SetupWorker are enqueued
- [ ] Gherkin scenarios for wizard phase pass

### Phase 3: SetupPhase LiveComponent

**Goal:** Phase 2 runs background workers and shows progress. Auto-advances to Phase 3 when done.

**Tasks:**

1. Create `lib/destila/workflows/setup_coordinator.ex`:
   - `maybe_advance_setup/1` — atomic CAS replacing `Destila.Setup.maybe_finish_phase0/1`
   - Checks `setup_steps` JSON on workflow_session for all steps completed
   - Advances `current_phase` from 2 to 3, sets `phase_status` to `nil`
   - Broadcasts `:workflow_session_updated`
2. Update `SetupWorker`:
   - Remove AI session creation step (no longer a setup concern)
   - Update `setup_steps` JSON on workflow_session after each step (e.g., `%{"repo_sync" => "completed"}`)
   - Call `SetupCoordinator.maybe_advance_setup/1` after last step
   - Steps: sync_repo → create_worktree (2 steps, not 3)
   - Create `AiSession` record with `worktree_path` after worktree creation
3. Update `TitleGenerationWorker`:
   - Update `setup_steps` JSON (e.g., `%{"title_gen" => "completed"}`)
   - Call `SetupCoordinator.maybe_advance_setup/1` after completion
4. Create `lib/destila_web/live/phases/setup_phase.ex`:
   - LiveComponent receiving `workflow_session`, `opts` as assigns
   - Subscribes to `"store:updates"` PubSub in `mount/1`
   - Implements `handle_info/2` for `:workflow_session_updated` — refreshes `setup_steps` from DB, detects title update, phase advance
   - Port setup progress UI from `SessionDetailLive` (task list with status icons)
   - Show steps based on project configuration:
     - With project: "Generating title...", "Pulling/Syncing...", "Creating worktree..."
     - Without project: "Generating title..." only
   - Show error + retry button for failed steps
   - Retry sends event to parent: `send(self(), {:phase_event, :retry_setup, %{}})`
   - When setup completes (detects `current_phase` change): `send(self(), {:phase_complete, 2, %{}})`
5. Update `WorkflowRunnerLive`:
   - On `{:phase_complete, 2, _}`: reload session from DB, mount AiConversationPhase for Phase 3
   - On PubSub `:workflow_session_updated`: check if `current_phase` changed (handles case where component wasn't mounted, e.g., user just navigated back)
   - Handle `:retry_setup` event: re-enqueue failed workers
6. Delete `lib/destila/setup.ex`
7. Write Gherkin feature file `features/setup_phase.feature`
8. Write tests:
   - SetupCoordinator unit tests (atomic CAS behavior)
   - SetupPhase LiveView integration tests (progress display, retry, auto-advance)

**Acceptance criteria:**
- [ ] Setup phase displays progress steps with live updates
- [ ] Setup completes → auto-advances to Phase 3
- [ ] Failed step shows error + retry button
- [ ] Works when user navigates away and returns (workers continue, state resumable)
- [ ] `Destila.Setup` deleted, `SetupCoordinator` in place
- [ ] Gherkin scenarios pass

### Phase 4: AiConversationPhase LiveComponent

**Goal:** AI conversation phases work end-to-end (Phases 3-6 of chore_task workflow).

**Tasks:**

1. Create `lib/destila_web/live/phases/ai_conversation_phase.ex`:
   - LiveComponent receiving `workflow_session`, `opts`, `phase_number`
   - Subscribes to `"store:updates"` PubSub in `mount/1`
   - Implements `handle_info/2` for `:message_added` — refreshes messages from DB, updates chat
   - Implements `handle_info/2` for `:workflow_session_updated` — detects phase_status changes
   - **Mount logic:** If this is the first AI phase AND no Phase 3 messages exist:
     - Create AI session via `AI.Session.for_workflow_session/2`
     - Build initial query (system prompt + user idea from Phase 1 messages)
     - Enqueue `AiQueryWorker` with phase 3 query
     - Set `phase_status: :generating`
   - **Chat rendering:** Reuse existing `ChatComponents` function components
     - Filter messages for phases up to and including current phase
     - Render phase dividers between phase groups (port from SessionDetailLive `phase_groups/2`)
     - Current phase messages rendered openly; past phases collapsed in `<details>`
   - **Input handling:** Dispatch based on `phase_status`:
     - `:generating` → typing indicator, input disabled
     - `:conversing` → text input enabled; single/multi select; multi-question
     - `:advance_suggested` → "Continue to Phase N" / "I have more to add" buttons
   - **Events (sent to parent via `send/2`):**
     - `send_text` → parent creates user message, enqueues AiQueryWorker
     - `select_single`, `select_multi`, `submit_all_answers` → same pattern
     - `confirm_advance` → parent advances phase
     - `decline_advance` → parent sets `phase_status: :conversing`
     - `mark_done` → parent marks workflow complete (only when `opts.final == true`)
   - **Opts-driven behavior:**
     - `skippable: true` → AiQueryWorker auto-advances on `<<SKIP_PHASE>>`
     - `final: true` → show "Mark as Done" instead of advance; render last AI message as prompt card
2. Update `WorkflowRunnerLive` event handlers:
   - Port `send_text`, `select_single`, `select_multi`, `submit_all_answers` from SessionDetailLive
   - Port `confirm_advance` / `decline_advance` with new column names
   - Port `mark_done` with new column names
   - Port `edit_title`, `save_title`, `archive_session`, `unarchive_session`
   - Handle `{:phase_complete, phase, _data}` for AI phases:
     - Update `current_phase` in DB
     - Mount new AiConversationPhase instance with next phase's opts
3. Update `AiQueryWorker`:
   - References to `steps_completed` → `current_phase`, `steps_total` → `total_phases`
   - `handle_skip_phase` updates `current_phase` instead of `steps_completed`
4. Update `Messages.parse_markers/3`:
   - Phase 6 (not 4) is now the final phase → `total_phases` parameter
5. Port phase divider CSS from `app.css` (keep existing styles)
6. Write Gherkin scenarios for `features/chore_task_workflow.feature`:
   - Phase 3: AI asks clarifying questions, user answers
   - Phase 4: Gherkin review, skip scenario
   - Phase 5: Technical concerns
   - Phase 6: Prompt generation, mark as done
   - Phase advance and decline flows
7. Write LiveView integration tests:
   - AI conversation rendering
   - Phase advance/decline
   - Phase skip
   - Mark as done
   - Resume after navigation away

**Acceptance criteria:**
- [ ] Full chore_task workflow runs end-to-end (Phase 1-6)
- [ ] AI conversation works with advance/decline/skip
- [ ] Final phase renders prompt card with copy/markdown toggle
- [ ] Mark as Done moves session to done column
- [ ] Phase dividers render correctly between phases
- [ ] Session resume works (navigate away and back)
- [ ] All Gherkin scenarios pass

### Phase 5: Cleanup & Integration

**Goal:** Delete old modules, update crafting board, verify all features work.

**Tasks:**

1. Delete old modules:
   - `lib/destila_web/live/new_session_live.ex`
   - `lib/destila_web/live/session_detail_live.ex`
   - `lib/destila_web/live/session_live.ex` (if not needed)
   - `test/destila_web/live/new_session_live_test.exs`
   - `test/destila_web/live/session_detail_live_test.exs`
   - `features/create_session_wizard.feature`
   - `features/phase_zero_setup.feature`
2. Update crafting board:
   - `WorkflowSessions.classify/1` — update to use `current_phase` + `phase_status`
   - `CraftingBoardLive` — update workflow view to use `total_phases`/`current_phase`
   - `BoardComponents` — update `phase_label/1` to use new column names
   - Remove references to deleted workflow types in any UI
   - Update "New Session" button to link to `/workflows/prompt_chore_task` (or a type selection page if needed later)
3. Update `features/crafting_board.feature`:
   - Remove scenarios referencing deleted workflow types
   - Update phase references
4. Verify unchanged features still work:
   - Session archiving
   - Generated prompt viewing
   - Project management
   - Project inline creation
5. Run `mix precommit` — fix all warnings, format, tests

**Acceptance criteria:**
- [ ] No dead code remaining
- [ ] Crafting board works with new phase model
- [ ] All existing features (archiving, prompt viewing, projects) unbroken
- [ ] `mix precommit` passes clean
- [ ] All Gherkin feature files up to date

## Gherkin Feature Files

### `features/setup_phase.feature`

```gherkin
Feature: Setup Phase
  The Setup Phase prepares the project environment before AI conversation
  phases begin. It runs as Phase 2 and includes steps for title generation,
  repository sync, and worktree creation.

  Background:
    Given I am logged in

  Scenario: Setup for a session with a local project
    Given I started a "Prompt for a Chore / Task" workflow with a local project
    Then I should see the setup phase with the following steps:
      | Generating title...       |
      | Pulling latest changes... |
      | Creating worktree...      |
    When all setup steps complete
    Then the setup phase should auto-collapse
    And Phase 3 - Task Description should begin automatically

  Scenario: Setup for a session with a remote-only project
    Given I started a "Prompt for a Chore / Task" workflow with a remote-only project
    Then I should see the setup phase with the following steps:
      | Generating title...    |
      | Syncing repository...  |
      | Creating worktree...   |
    When all setup steps complete
    Then Phase 3 - Task Description should begin automatically

  Scenario: Setup for a session without a linked project
    Given I started a "Prompt for a Chore / Task" workflow without a project
    Then I should only see the step "Generating title..."
    When the title is generated
    Then the setup phase should auto-collapse
    And Phase 3 - Task Description should begin automatically

  Scenario: A setup step fails
    Given setup is running for my session
    And a step fails due to an error
    Then I should see the error message for the failed step
    And I should see a "Retry" button
    When I click "Retry"
    Then the failed step should be attempted again

  Scenario: User navigates away during setup
    Given setup is running for my session
    When I navigate to another page
    Then the setup should continue running in the background
    When I return to the session detail page
    Then I should see the current setup progress

  Scenario: Chat input disabled during setup phase
    Given setup is running for my session
    When I am on the session detail page
    Then the chat input should be disabled
    When setup completes
    Then the chat input should be enabled
```

### `features/chore_task_workflow.feature`

```gherkin
Feature: Prompt for a Chore / Task Workflow
  The "Prompt for a Chore / Task" workflow uses AI-driven conversational phases
  to refine a coding task into an implementation prompt. It progresses through
  six phases:
  1. Project & Idea - Wizard collecting project and initial task description
  2. Setup - Prepares the project environment (repo sync, worktree, title)
  3. Task Description - AI asks clarifying questions about the task
  4. Gherkin Review - AI reviews or proposes BDD feature scenarios
  5. Technical Concerns - AI explores technical approach and trade-offs
  6. Prompt Generation - AI generates the final implementation prompt

  Background:
    Given I am logged in

  Scenario: Phase 1 - Wizard collects project and idea
    When I navigate to start a new "Prompt for a Chore / Task" workflow
    Then I should see a form to select a project and describe my idea
    When I select a project and enter my initial idea
    And I click "Start"
    Then a workflow session should be created
    And I should be redirected to the session detail page
    And Phase 2 - Setup should begin automatically

  Scenario: Phase 1 - Create project inline during wizard
    When I navigate to start a new "Prompt for a Chore / Task" workflow
    And I click "Create New Project"
    Then I should see the inline project creation form
    When I fill in the project details and create it
    Then the new project should be selected

  Scenario: Phase 2 - Setup runs automatically
    Given I completed the wizard and am on the session detail page
    Then I should see the setup progress
    And the progress bar should show "Phase 2/6 - Setup"
    When setup completes
    Then Phase 3 - Task Description should begin automatically

  Scenario: Phase 3 - AI asks clarifying questions
    Given the session is in Phase 3 - Task Description
    Then the AI should ask clarifying questions about the task
    And the progress bar should show "Phase 3/6 - Task Description"
    When I answer the AI's questions
    Then the AI may ask follow-up questions or suggest advancing

  Scenario: Advance to the next phase
    Given the AI suggests advancing from the current phase
    Then I should see a "Continue to Phase N" button
    When I click the continue button
    Then a phase divider should appear in the chat
    And the progress bar should update to show the next phase

  Scenario: Decline phase advance to add more context
    Given the AI suggests advancing from the current phase
    When I click "I have more to add"
    Then the text input should be re-enabled
    And I should be able to continue the conversation in the current phase

  Scenario: Phase 4 - Gherkin Review
    Given the session is in Phase 4 - Gherkin Review
    Then the AI should review or propose Gherkin feature scenarios
    When the user and AI agree on the scenarios
    Then the AI should suggest advancing

  Scenario: Skip Gherkin Review when not applicable
    Given the session is in Phase 4 - Gherkin Review
    When the AI determines Gherkin scenarios are not needed
    Then the phase should be automatically skipped
    And a phase divider should appear in the chat
    And the workflow should advance to Phase 5 - Technical Concerns

  Scenario: Phase 5 - Technical Concerns
    Given the session is in Phase 5 - Technical Concerns
    Then the AI should ask about the technical approach
    When the technical approach is discussed and agreed upon
    Then the AI should suggest advancing

  Scenario: Phase 6 - Prompt Generation and mark as done
    Given the session is in Phase 6 - Prompt Generation
    Then the AI should generate an implementation prompt
    And the prompt should be displayed in a styled card
    When I am satisfied with the generated prompt
    And I click "Mark as Done"
    Then the workflow should be marked as complete
    And the session should move to the done column
```

## Acceptance Criteria

### Functional Requirements

- [ ] Full `prompt_chore_task` workflow runs end-to-end (6 phases)
- [ ] Wizard phase collects project + idea, creates session
- [ ] Setup phase shows progress, handles failures, auto-advances
- [ ] AI conversation phases work with advance/decline/skip/mark-done
- [ ] Phase dividers render between conversation phases
- [ ] Progress bar shows "Phase X/6 — Name" throughout
- [ ] Session resume works after navigation away
- [ ] Crafting board displays sessions correctly with new phase model
- [ ] Group by Workflow view works with updated phase columns
- [ ] Session archiving works from WorkflowRunnerLive
- [ ] Title editing works after session creation
- [ ] Generated prompt card with copy/markdown toggle works in Phase 6

### Non-Functional Requirements

- [ ] No dead code from old architecture
- [ ] `mix precommit` passes clean
- [ ] All Gherkin feature files updated and scenarios tagged in tests
- [ ] LiveComponent pattern documented (CLAUDE.md updated)

## Dependencies & Risks

**Risk: LiveComponent is new to this codebase.** No existing patterns to follow. Mitigated by starting with the simplest component (WizardPhase) and building complexity incrementally.

**Risk: Chat component events assume parent LiveView.** All `ChatComponents` function components dispatch events via `phx-click` to the parent. In the LiveComponent model, the parent is still the LiveView (not the component), so existing event names work. But the event handlers move from SessionDetailLive to WorkflowRunnerLive.

**Risk: Setup coordination race conditions.** The CAS pattern is proven (exists in current code). The new `SetupCoordinator` uses the same pattern — risk is low.

**Risk: Large diff.** Deleting SessionDetailLive (834 lines) and NewSessionLive (583 lines) while creating new modules is a significant change. Mitigated by the phased implementation approach — each phase can be tested independently.

## References

- Brainstorm: `docs/brainstorms/2026-03-25-workflow-phase-architecture-brainstorm.md`
- Current SessionDetailLive: `lib/destila_web/live/session_detail_live.ex`
- Current NewSessionLive: `lib/destila_web/live/new_session_live.ex`
- Current Setup coordination: `lib/destila/setup.ex`
- Current workflow module: `lib/destila/workflows/prompt_chore_task_workflow.ex`
- ChatComponents (reused): `lib/destila_web/components/chat_components.ex`
- AI Session: `lib/destila/ai/session.ex`
