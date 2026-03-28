---
title: "refactor: Extract business logic from web layer into core modules"
type: refactor
date: 2026-03-27
---

# refactor: Extract business logic from web layer into core modules

## Overview

Move all business logic (DB mutations, Oban job insertion, AI session management, validation) out of the four DestilaWeb files (WorkflowRunnerLive, WizardPhase, SetupPhase, AiConversationPhase) into the Destila core layer. After this refactor, every web-layer module is a thin delegate: receive events, call core functions, update socket assigns with results.

## Problem Statement

Business logic is scattered across LiveView and LiveComponent files that should be pure presentation:

- **WorkflowRunnerLive** — session creation from wizard data, mark-done with AI completion message, phase advancement
- **WizardPhase** — project validation, inline project creation with validation
- **SetupPhase** — `Oban.insert` calls for SetupWorker/TitleGenerationWorker, idempotency guard, retry logic
- **AiConversationPhase** — AI session creation, `Oban.insert` for AiQueryWorker, phase advancement with session strategy, duplicated mark-done logic

Additionally, `AiQueryWorker.handle_skip_phase/2` contains phase-advance logic that parallels `AiConversationPhase.handle_event("confirm_advance")` — both check session strategy and optionally stop ClaudeSession.

## Proposed Solution

Extract business logic into two targets:

1. **`Destila.Workflows`** (context module) — generic runner-level operations: session creation from wizard, phase advancement with session strategy, mark-done
2. **`Destila.Workflows.PromptChoreTaskWorkflow`** — workflow-specific phase operations: setup initiation/retry, AI conversation initialization, send user message

The `Workflows` dispatcher routes to concrete workflow functions where needed, consistent with existing pattern.

## Technical Approach

### Architecture

```
Before:
  WorkflowRunnerLive ──── DB writes, AI calls, Oban inserts
  WizardPhase ──────────── Projects.create_project, validation
  SetupPhase ───────────── Oban.insert(SetupWorker), Oban.insert(TitleGenWorker)
  AiConversationPhase ──── AI session mgmt, Oban.insert(AiQueryWorker), phase advance
  AiQueryWorker ────────── handle_skip_phase (parallel advance logic)

After:
  WorkflowRunnerLive ──── calls Workflows.create_session_from_wizard/2
                           calls Workflows.advance_phase/1
                           calls Workflows.mark_done/1

  WizardPhase ──────────── calls Workflows.validate_wizard_fields/2
                           calls Workflows.validate_and_create_project/2

  SetupPhase ───────────── calls Workflows.initiate_setup/2
                           calls Workflows.retry_setup/1
                           keeps build_steps (presentation logic)

  AiConversationPhase ──── calls Workflows.initialize_ai_conversation/3
                           calls Workflows.send_user_message/3
                           calls Workflows.advance_phase/1
                           calls Workflows.mark_done/1

  AiQueryWorker ────────── calls Workflows.advance_phase/1
                           handles auto-enqueue of next phase (worker-specific)
```

### Key Design Decisions

**1. Two advance_phase paths, shared core**

`confirm_advance` (LiveComponent) and `handle_skip_phase` (Worker) have different post-advance needs:
- LiveComponent: sets `phase_status: nil`, sends `{:phase_advanced}` to parent, component re-initializes on next `update/2`
- Worker: sets `phase_status: :generating`, immediately enqueues next phase's AiQueryWorker

Solution: `Workflows.advance_phase/1` handles the shared core (session strategy check, optional ClaudeSession stop, DB update to `current_phase + 1`). It accepts an optional `phase_status` parameter (defaults to `nil`). The worker passes `phase_status: :generating` and handles the enqueue itself.

```elixir
# lib/destila/workflows.ex
def advance_phase(workflow_session, opts \\ []) do
  next_phase = workflow_session.current_phase + 1
  if next_phase > workflow_session.total_phases, do: {:error, :at_boundary}

  {action, _} = session_strategy(workflow_session.workflow_type, next_phase)
  if action == :new, do: AI.ClaudeSession.stop_for_workflow_session(workflow_session.id)

  phase_status = Keyword.get(opts, :phase_status, nil)
  update_workflow_session(workflow_session, %{current_phase: next_phase, phase_status: phase_status})
end
```

**2. `build_steps` stays in SetupPhase**

`build_steps/2` constructs display structs with UI labels ("Syncing repository...", "Pulling latest changes..."). This is presentation logic, not business logic. Only `initiate_setup` (status update + worker enqueuing) and `retry_setup` (re-enqueuing) move to the business layer.

**3. `connected?` guards stay in the web layer**

`SetupPhase.update/2` and `AiConversationPhase.update/2` check `connected?(socket)` before triggering side effects. Context modules have no socket awareness. The web layer retains these guards; extracted functions document the contract ("must only be called from a connected LiveView").

**4. No transaction for session creation + metadata**

`create_session_from_wizard/2` performs two DB operations (insert session, upsert idea metadata). Wrapping in `Ecto.Multi` is not needed — the metadata upsert is extremely unlikely to fail, and the impact of a missing idea is minor (AI phase works without it). Keep as-is for simplicity.

**5. Return value contracts**

All extracted functions that mutate a workflow session return `{:ok, updated_session}`. Fire-and-forget operations (setup initiation, retry) return `:ok`. Functions that need to return additional data (e.g., `initialize_ai_conversation` returning the AI session) return `{:ok, ai_session}`.

**6. Unified mark_done**

Both `WorkflowRunnerLive` and `AiConversationPhase` have mark_done handlers. After extraction, both call `Workflows.mark_done/1`. The LiveComponent caller additionally sends `:workflow_done` to the parent — this notification remains in the web layer, not in the extracted function.

### Implementation Phases

#### Phase 1: Extract runner-level logic to Workflows context

Extract three functions into `lib/destila/workflows.ex`:

**`create_session_from_wizard/2`**

```elixir
# Workflows.create_session_from_wizard(workflow_type, wizard_data)
# wizard_data: %{project_id: id, idea: text, title_generating: bool}
# Returns: {:ok, session}
def create_session_from_wizard(workflow_type, data) do
  session_attrs =
    %{
      title: default_title(workflow_type),
      workflow_type: workflow_type,
      current_phase: 2,  # wizard is phase 1, next is 2
      total_phases: total_phases(workflow_type)
    }
    |> maybe_put(:project_id, data[:project_id])
    |> maybe_put(:title_generating, data[:title_generating])

  {:ok, ws} = create_workflow_session(session_attrs)

  if data[:idea] do
    upsert_metadata(ws.id, "wizard", "idea", %{"text" => data[:idea]})
  end

  {:ok, ws}
end
```

**`advance_phase/2`**

```elixir
# Workflows.advance_phase(workflow_session, opts \\ [])
# opts: [phase_status: atom] — defaults to nil
# Returns: {:ok, updated_session} | {:error, :at_boundary}
def advance_phase(%Session{} = ws, opts \\ []) do
  next_phase = ws.current_phase + 1

  if next_phase > ws.total_phases do
    {:error, :at_boundary}
  else
    {action, _} = session_strategy(ws.workflow_type, next_phase)

    if action == :new do
      Destila.AI.ClaudeSession.stop_for_workflow_session(ws.id)
    end

    phase_status = Keyword.get(opts, :phase_status)
    update_workflow_session(ws, %{current_phase: next_phase, phase_status: phase_status})
  end
end
```

**`mark_done/1`**

```elixir
# Workflows.mark_done(workflow_session)
# Returns: {:ok, updated_session}
def mark_done(%Session{} = ws) do
  ai_session = Destila.AI.get_ai_session_for_workflow(ws.id)

  if ai_session do
    Destila.AI.create_message(ai_session.id, %{
      role: :system,
      content: completion_message(ws.workflow_type),
      phase: ws.current_phase
    })
  end

  update_workflow_session(ws, %{done_at: DateTime.utc_now(), phase_status: nil})
end
```

**Update WorkflowRunnerLive** — replace inline logic with calls:

```elixir
# workflow_runner_live.ex — handle_info for session creation
def handle_info({:phase_complete, _phase, %{action: :session_create} = data}, socket) do
  {:ok, ws} = Workflows.create_session_from_wizard(socket.assigns.workflow_type, data)
  {:noreply, push_navigate(socket, to: ~p"/sessions/#{ws.id}")}
end

# handle_info for simple phase advance
def handle_info({:phase_complete, _phase, _data}, socket) do
  {:ok, ws} = Workflows.advance_phase(socket.assigns.workflow_session)
  {:noreply,
   socket
   |> assign(:workflow_session, ws)
   |> assign(:current_phase, ws.current_phase)
   |> assign(:metadata, Workflows.get_metadata(ws.id))
   |> assign(:page_title, ws.title)}
end

# handle_event for mark_done
def handle_event("mark_done", _params, socket) do
  {:ok, ws} = Workflows.mark_done(socket.assigns.workflow_session)
  {:noreply, assign(socket, :workflow_session, ws)}
end
```

**Tests:** Unit tests for `create_session_from_wizard/2`, `advance_phase/2`, `mark_done/1`.

- `workflow_runner_live.ex:157-195` — session creation + phase advance handlers
- `workflow_runner_live.ex:133-152` — mark_done handler
- `workflows.ex` — new functions added

**Success criteria:** `mix precommit` passes. All existing feature tests pass.

---

#### Phase 2: Extract WizardPhase business logic

Add two dispatcher functions to `Workflows` that delegate to `PromptChoreTaskWorkflow`:

**`validate_wizard_fields/2`** (in PromptChoreTaskWorkflow)

```elixir
# PromptChoreTaskWorkflow.validate_wizard_fields(params)
# params: %{project_id: id | nil, idea: string}
# Returns: :ok | {:error, errors_map}
def validate_wizard_fields(%{project_id: project_id, idea: idea}) do
  errors = %{}
  errors = if is_nil(project_id), do: Map.put(errors, :project, "Please select a project"), else: errors
  errors = if idea == "" or is_nil(idea), do: Map.put(errors, :idea, "Please describe your initial idea"), else: errors
  if errors == %{}, do: :ok, else: {:error, errors}
end
```

**`validate_and_create_project/2`** (in PromptChoreTaskWorkflow)

```elixir
# PromptChoreTaskWorkflow.validate_and_create_project(params)
# Returns: {:ok, project} | {:error, errors_map}
def validate_and_create_project(params) do
  name = String.trim(params["name"] || "")
  git_repo_url = non_blank(params["git_repo_url"])
  local_folder = non_blank(params["local_folder"])

  errors = %{}
  errors = if name == "", do: Map.put(errors, :name, "Name is required"), else: errors
  errors =
    if git_repo_url == nil && local_folder == nil,
      do: Map.put(errors, :location, "Provide at least one"),
      else: errors

  if errors == %{} do
    Destila.Projects.create_project(%{
      name: name,
      git_repo_url: git_repo_url,
      local_folder: local_folder
    })
  else
    {:error, errors}
  end
end
```

**Dispatcher functions in `Workflows`:**

```elixir
def validate_wizard_fields(workflow_type, params) do
  workflow_module(workflow_type).validate_wizard_fields(params)
end

def validate_and_create_project(workflow_type, params) do
  workflow_module(workflow_type).validate_and_create_project(params)
end
```

**Update WizardPhase** — replace inline validation/creation:

```elixir
def handle_event("create_and_select_project", params, socket) do
  case Workflows.validate_and_create_project(socket.assigns.workflow_type, params) do
    {:ok, project} ->
      {:noreply,
       socket
       |> assign(:project_id, project.id)
       |> assign(:projects, Destila.Projects.list_projects())
       |> assign(:project_step, :select)
       |> assign(:errors, %{})}

    {:error, errors} ->
      {:noreply,
       socket
       |> assign(:project_form, to_form(params))
       |> assign(:errors, errors)}
  end
end

def handle_event("start_workflow", %{"initial_idea" => idea}, socket) when idea != "" do
  case Workflows.validate_wizard_fields(socket.assigns.workflow_type, %{
    project_id: socket.assigns.project_id,
    idea: idea
  }) do
    :ok ->
      send(self(), {:phase_complete, socket.assigns.phase_number, %{
        action: :session_create,
        project_id: socket.assigns.project_id,
        idea: idea,
        title_generating: true
      }})
      {:noreply, socket}

    {:error, errors} ->
      {:noreply, assign(socket, :errors, errors)}
  end
end
```

Note: WizardPhase needs `workflow_type` passed as an assign from the parent. Currently it only receives `opts` and `phase_number` — `update/2` must also capture `assigns.workflow_type`.

**Tests:** Unit tests for `validate_wizard_fields/1`, `validate_and_create_project/1`.

- `wizard_phase.ex:41-115` — validation and creation handlers
- `prompt_chore_task_workflow.ex` — new functions added
- `workflows.ex` — new dispatcher functions

**Success criteria:** `mix precommit` passes. All existing feature tests pass.

---

#### Phase 3: Extract SetupPhase business logic

Add two functions to `PromptChoreTaskWorkflow`:

**`initiate_setup/2`**

```elixir
# PromptChoreTaskWorkflow.initiate_setup(workflow_session, metadata)
# Returns: :ok
# IMPORTANT: Must only be called from a connected LiveView (not static render).
def initiate_setup(%Session{phase_status: :setup}, _metadata), do: :ok

def initiate_setup(ws, metadata) do
  Destila.Workflows.update_workflow_session(ws, %{phase_status: :setup})

  idea = get_in(metadata, ["idea", "text"]) || ""

  %{"workflow_session_id" => ws.id, "idea" => idea}
  |> Destila.Workers.TitleGenerationWorker.new()
  |> Oban.insert()

  if ws.project_id do
    %{"workflow_session_id" => ws.id}
    |> Destila.Workers.SetupWorker.new()
    |> Oban.insert()
  end

  :ok
end
```

**`retry_setup/1`**

```elixir
# PromptChoreTaskWorkflow.retry_setup(workflow_session)
# Returns: :ok
def retry_setup(ws) do
  if ws.project_id do
    %{"workflow_session_id" => ws.id}
    |> Destila.Workers.SetupWorker.new()
    |> Oban.insert()
  end

  if ws.title_generating do
    %{"workflow_session_id" => ws.id, "idea" => ""}
    |> Destila.Workers.TitleGenerationWorker.new()
    |> Oban.insert()
  end

  :ok
end
```

**Dispatcher functions in `Workflows`:**

```elixir
def initiate_setup(workflow_type, workflow_session, metadata) do
  workflow_module(workflow_type).initiate_setup(workflow_session, metadata)
end

def retry_setup(workflow_type, workflow_session) do
  workflow_module(workflow_type).retry_setup(workflow_session)
end
```

**Update SetupPhase:**

```elixir
def update(assigns, socket) do
  ws = assigns.workflow_session
  metadata = assigns[:metadata] || %{}
  steps = build_steps(ws, metadata)  # stays in component

  if connected?(socket) && ws do  # connected? guard stays in web layer
    Workflows.initiate_setup(ws.workflow_type, ws, metadata)
  end

  if all_completed?(steps) do
    send(self(), {:phase_complete, assigns.phase_number, %{}})
  end

  {:ok, socket |> assign(...)}
end

def handle_event("retry_setup", _params, socket) do
  ws = socket.assigns.workflow_session
  Workflows.retry_setup(ws.workflow_type, ws)
  {:noreply, socket}
end
```

**Tests:** Unit tests for `initiate_setup/2`, `retry_setup/1`.

- `setup_phase.ex:11-49` — update and retry handlers
- `setup_phase.ex:95-111` — maybe_start_setup logic
- `prompt_chore_task_workflow.ex` — new functions added
- `workflows.ex` — new dispatcher functions

**Success criteria:** `mix precommit` passes. All existing feature tests pass.

---

#### Phase 4: Extract AiConversationPhase business logic

This is the largest extraction. Add functions to `PromptChoreTaskWorkflow` and update `Workflows`:

**`initialize_ai_conversation/3`** (in PromptChoreTaskWorkflow)

```elixir
# PromptChoreTaskWorkflow.initialize_ai_conversation(ws, phase_number, opts)
# Returns: {:ok, ai_session} | :already_initialized
# IMPORTANT: Must only be called from a connected LiveView (not static render).
def initialize_ai_conversation(ws, phase_number, opts) do
  ai_session = Destila.AI.get_ai_session_for_workflow(ws.id)
  messages = if ai_session, do: Destila.AI.list_messages(ai_session.id), else: []
  phase_messages = Enum.filter(messages, &(&1.phase == phase_number))

  if phase_messages == [] && ws.phase_status != :generating do
    ai_session =
      if ai_session do
        ai_session
      else
        metadata = Destila.Workflows.get_metadata(ws.id)
        worktree_path = get_in(metadata, ["worktree", "worktree_path"])
        {:ok, session} = Destila.AI.get_or_create_ai_session(ws.id, %{worktree_path: worktree_path})
        session
      end

    system_prompt_fn = Keyword.fetch!(opts, :system_prompt)
    query = system_prompt_fn.(ws)

    Destila.Workflows.update_workflow_session(ws, %{phase_status: :generating})

    %{"workflow_session_id" => ws.id, "phase" => phase_number, "query" => query}
    |> Destila.Workers.AiQueryWorker.new()
    |> Oban.insert()

    {:ok, ai_session}
  else
    :already_initialized
  end
end
```

**`send_user_message/3`** (in PromptChoreTaskWorkflow)

```elixir
# PromptChoreTaskWorkflow.send_user_message(ws, ai_session, content)
# Returns: {:ok, updated_ws} | {:error, :generating}
def send_user_message(ws, ai_session, content) do
  if ws.phase_status in [:generating] do
    {:error, :generating}
  else
    Destila.AI.create_message(ai_session.id, %{
      role: :user,
      content: content,
      phase: ws.current_phase
    })

    {:ok, ws} = Destila.Workflows.update_workflow_session(ws, %{phase_status: :generating})

    %{"workflow_session_id" => ws.id, "phase" => ws.current_phase, "query" => content}
    |> Destila.Workers.AiQueryWorker.new()
    |> Oban.insert()

    {:ok, ws}
  end
end
```

**Dispatcher functions in `Workflows`:**

```elixir
def initialize_ai_conversation(workflow_type, ws, phase_number, opts) do
  workflow_module(workflow_type).initialize_ai_conversation(ws, phase_number, opts)
end

def send_user_message(workflow_type, ws, ai_session, content) do
  workflow_module(workflow_type).send_user_message(ws, ai_session, content)
end
```

**Update AiConversationPhase** — replace all business logic calls:

```elixir
defp maybe_initialize_ai(socket, ws, _ai_session, phase_number, opts) do
  case Workflows.initialize_ai_conversation(ws.workflow_type, ws, phase_number, opts) do
    {:ok, ai_session} -> assign(socket, :ai_session, ai_session)
    :already_initialized -> socket
  end
end

def handle_event("send_text", %{"content" => content}, socket) when content != "" do
  ws = socket.assigns.workflow_session
  ai_session = socket.assigns.ai_session

  if ai_session do
    case Workflows.send_user_message(ws.workflow_type, ws, ai_session, content) do
      {:ok, ws} ->
        messages = AI.list_messages(ai_session.id)
        {:noreply,
         socket
         |> assign(:workflow_session, ws)
         |> assign(:messages, messages)
         |> assign(:current_step, compute_current_step(ws, messages))}

      {:error, :generating} ->
        {:noreply, socket}
    end
  else
    {:noreply, socket}
  end
end

def handle_event("confirm_advance", _params, socket) do
  ws = socket.assigns.workflow_session

  case Workflows.advance_phase(ws) do
    {:ok, updated_ws} ->
      send(self(), {:phase_advanced, updated_ws.current_phase})
      {:noreply,
       socket
       |> assign(:workflow_session, updated_ws)
       |> assign(:phase_number, updated_ws.current_phase)
       |> assign(:question_answers, %{})
       |> assign(:initialized, false)}

    {:error, :at_boundary} ->
      {:noreply, socket}
  end
end

def handle_event("mark_done", _params, socket) do
  {:ok, ws} = Workflows.mark_done(socket.assigns.workflow_session)
  send(self(), :workflow_done)
  {:noreply, assign(socket, :workflow_session, ws)}
end
```

**Update AiQueryWorker** — use `Workflows.advance_phase/2` in `handle_skip_phase`:

```elixir
defp handle_skip_phase(workflow_session_id, current_phase) do
  ws = Workflows.get_workflow_session!(workflow_session_id)

  case Workflows.advance_phase(ws, phase_status: :generating) do
    {:ok, updated_ws} ->
      # Enqueue AI query for the next phase
      phases = Workflows.phases(updated_ws.workflow_type)
      {_module, opts} = Enum.at(phases, updated_ws.current_phase - 1)
      system_prompt_fn = Keyword.fetch!(opts, :system_prompt)
      phase_prompt = system_prompt_fn.(updated_ws)

      %{
        "workflow_session_id" => workflow_session_id,
        "phase" => updated_ws.current_phase,
        "query" => phase_prompt
      }
      |> __MODULE__.new()
      |> Oban.insert()

    {:error, :at_boundary} ->
      Workflows.update_workflow_session(workflow_session_id, %{phase_status: :conversing})
  end
end
```

**Tests:** Unit tests for `initialize_ai_conversation/3`, `send_user_message/3`.

- `ai_conversation_phase.ex:87-119` — send_text handler
- `ai_conversation_phase.ex:199-227` — confirm_advance handler
- `ai_conversation_phase.ex:235-256` — mark_done handler
- `ai_conversation_phase.ex:358-389` — maybe_initialize_ai
- `ai_query_worker.ex:97-132` — handle_skip_phase
- `prompt_chore_task_workflow.ex` — new functions added
- `workflows.ex` — new dispatcher functions

**Success criteria:** `mix precommit` passes. All existing feature tests pass.

---

#### Phase 5: Verification and cleanup

- [x] Run full test suite: `mix test`
- [x] Run precommit: `mix precommit`
- [x] Verify no direct `Oban.insert` calls remain in `lib/destila_web/`
- [x] Verify no direct `Destila.AI.*` calls remain in `lib/destila_web/` (except `AI.process_message` and `AI.list_messages` which are read-only display helpers used in `compute_current_step` and `refresh_from_db`)
- [x] Verify no direct `Destila.Projects.create_project` calls remain in `lib/destila_web/`
- [x] Verify all 7 feature files' scenarios are still covered by passing tests

## Acceptance Criteria

### Functional Requirements

- [x] All existing Gherkin scenarios pass without modification
- [x] All existing tests pass without modification
- [x] No user-facing behavior changes

### Architecture Requirements

- [x] No `Oban.insert` calls in `lib/destila_web/`
- [x] No `Destila.AI.create_message`, `AI.get_or_create_ai_session`, `AI.ClaudeSession.stop_for_workflow_session` calls in `lib/destila_web/`
- [x] No `Destila.Projects.create_project` calls in `lib/destila_web/`
- [x] No business validation logic in `lib/destila_web/`
- [x] `Workflows.advance_phase/2` used by both `AiConversationPhase` and `AiQueryWorker` (single source of truth for phase advancement)
- [x] `Workflows.mark_done/1` used by both `WorkflowRunnerLive` and `AiConversationPhase` (unified mark-done)

### Quality Requirements

- [x] Unit tests for every new function in `Workflows` and `PromptChoreTaskWorkflow`
- [x] `mix precommit` passes after each phase

## Allowed read-only calls in web layer

These calls remain in the web layer as they are read-only display helpers, not business logic:

- `Workflows.get_metadata/1`, `Workflows.get_workflow_session!/1` — data fetching for assigns
- `Workflows.phase_name/2`, `Workflows.phases/1` — phase metadata for display
- `Workflows.classify/1` — classification for crafting board display
- `AI.list_messages/1`, `AI.get_ai_session_for_workflow/1` — loading messages for display
- `AI.process_message/2` — deriving display state from raw AI response
- `Projects.list_projects/0`, `Projects.get_project/1` — loading data for display
- `Session.done?/1` — predicate for template conditionals

## References

### Internal References

- `lib/destila_web/live/workflow_runner_live.ex` — runner with inline business logic
- `lib/destila_web/live/phases/wizard_phase.ex` — wizard with validation and project creation
- `lib/destila_web/live/phases/setup_phase.ex` — setup with Oban job insertion
- `lib/destila_web/live/phases/ai_conversation_phase.ex` — AI chat with session mgmt and job insertion
- `lib/destila/workers/ai_query_worker.ex:97-132` — handle_skip_phase parallel advance logic
- `lib/destila/workflows.ex` — target for generic extracted functions
- `lib/destila/workflows/prompt_chore_task_workflow.ex` — target for workflow-specific functions

### Prior Work

- `docs/brainstorms/2026-03-25-workflow-phase-architecture-brainstorm.md` — established current architecture
- `docs/plans/2026-03-25-refactor-workflow-phase-architecture-plan.md` — implemented current phase system
