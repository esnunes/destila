# Restructure Workflow System — Implementation Plan

## 1. Deep Audit of the Existing Workflow System

### 1.1 Structural Audit

#### 1. Where are workflows defined?

Workflows are defined **in Elixir modules** — not in the database.

| Module | Purpose |
|--------|---------|
| `Destila.Workflows` (`lib/destila/workflows.ex`) | Thin dispatcher; routes operations to workflow modules via a compile-time `@workflow_modules` map |
| `Destila.Workflows.PromptChoreTaskWorkflow` (`lib/destila/workflows/prompt_chore_task_workflow.ex`) | 6-phase "Chore/Task" workflow definition |
| `Destila.Workflows.ImplementGeneralPromptWorkflow` (`lib/destila/workflows/implement_general_prompt_workflow.ex`) | 9-phase "Implement Prompt" workflow definition |

Each workflow module exports: `phases/0`, `total_phases/0`, `phase_name/1`, `phase_columns/0`, `label/0`, `description/0`, `icon/0`, `icon_class/0`, `default_title/0`, `completion_message/0`, and optionally `session_strategy/1`.

No database tables store workflow definitions. The `workflow_sessions.workflow_type` column (an Ecto enum) is the only DB link to definitions — it stores an atom key that maps to a module.

#### 2. Where are phases defined?

Phases are **tuples embedded in each workflow module's `phases/0` function**: `{LiveComponent, keyword_opts}`.

```elixir
# Example from PromptChoreTaskWorkflow
{DestilaWeb.Phases.AiConversationPhase, name: "Task Description", system_prompt: &task_description_prompt/1}
```

Phase types (LiveComponents):
- `DestilaWeb.Phases.WizardPhase` — project + idea selection (Phase 1 of PromptChoreTask)
- `DestilaWeb.Phases.PromptWizardPhase` — prompt + project selection (Phase 1 of ImplementGeneralPrompt)
- `DestilaWeb.Phases.SetupPhase` — repo sync + worktree creation (Phase 2 in both)
- `DestilaWeb.Phases.AiConversationPhase` — interactive/non-interactive AI conversation (all remaining phases)

Phases **cannot be shared across workflows today** because the phase tuples reference workflow-specific prompts via function captures. The LiveComponent types are shared, but configurations are workflow-specific.

#### 3. How is workflow state tracked?

**Execution concept:** `workflow_sessions` table = one row per user-workflow run.

- `current_phase` (integer) — which phase the user is on (1-indexed)
- `total_phases` (integer) — total phase count
- `phase_status` (enum: `setup | generating | conversing | advance_suggested`) — status within the current phase
- `done_at` (datetime) — when workflow completed
- `archived_at` (datetime) — when archived

**Phase-level state** is tracked implicitly:
- There is **no `phase_executions` table** — phase status lives on the workflow session row
- Phase results are stored in `workflow_session_metadata` (KV pairs keyed by `phase_name` + `key`)
- Phase messages are stored in `messages` (linked to `ai_sessions`, tagged with `phase` integer)

**AI session state:**
- `ai_sessions` table tracks the ClaudeCode session ID and worktree path
- A workflow session can have multiple AI sessions (e.g., ImplementGeneralPrompt creates a new one at phase 5)
- The most recent AI session is fetched via `order_by: [desc: :inserted_at], limit: 1`

#### 4. How do transitions happen?

There is **no central engine module**. Transition logic is spread across three locations:

1. **`WorkflowRunnerLive.handle_info({:phase_complete, ...})`** (lines 157-221) — handles wizard phase completion and session creation, or increments `current_phase`
2. **`AiConversationPhase.handle_event("confirm_advance", ...)`** (lines 183-211) — user confirms AI's suggestion to advance; stops/creates AI sessions as needed, updates workflow session, sends `:phase_advanced` to parent
3. **`AiQueryWorker.handle_skip_phase/2`** (lines 116-178) — after AI calls `phase_complete` tool; handles auto-advancement, session strategy (`:new` vs `:resume`), and enqueuing the next non-interactive phase's worker

Call path for "user completes a step" → "next step begins":
1. **Interactive → next interactive:** User clicks "Next Phase" → `confirm_advance` event → updates `current_phase` in DB → PubSub broadcasts → parent LiveView re-renders with new phase component → new component's `maybe_initialize_ai/5` sends system prompt via Oban worker
2. **Non-interactive → non-interactive:** `AiQueryWorker` receives `phase_complete` from AI → `handle_skip_phase` advances phase → enqueues next worker → PubSub notifies LiveView
3. **Non-interactive → interactive:** Same as above but `handle_skip_phase` just advances the phase without enqueuing; LiveView re-renders interactive component

#### 5. How are interactive phases handled?

**Chat phases** (`AiConversationPhase`):
- User types text → `send_text` event → saves user message to DB → enqueues `AiQueryWorker` → worker calls ClaudeCode via `ClaudeSession` GenServer → saves AI response to DB → broadcasts via PubSub → LiveView re-renders
- AI can present structured questions via `mcp__destila__ask_user_question` tool → extracted from raw_response by `AI.process_message/2` → rendered as radio/checkbox UI by `ChatComponents`
- AI can suggest phase completion via `mcp__destila__session` tool → sets `phase_status: :advance_suggested` → UI shows "Next Phase" / "Continue Conversation" buttons

**Form phases:** There is **no form executor**. The wizard phases (`WizardPhase`, `PromptWizardPhase`) are custom LiveComponents with hardcoded form logic, not generic form handlers.

**Component dispatch:** `WorkflowRunnerLive.render_phase/1` dispatches to the right LiveComponent based on the `{module, opts}` tuple from the phase list. This is generic — adding a new component type just requires adding a new LiveComponent module.

#### 6. How is async work handled?

**Oban workers:**
- `AiQueryWorker` — queue `:default`, max 1 attempt, unique per (workflow_session_id, phase) for 30s
- `SetupWorker` — queue `:setup` (1 concurrency), max 3 attempts
- `TitleGenerationWorker` — queue `:default`, max 3 attempts

**GenServer:** `ClaudeSession` wraps `ClaudeCode.start_link` with Registry-based singleton per workflow session and 5-minute inactivity timeout.

**UI notification:** PubSub on `"store:updates"` topic. Workers update DB state → `broadcast/2` fires → LiveView `handle_info` reloads and re-renders. Single global topic for all events.

#### 7. Data model

| Table | Columns | Purpose |
|-------|---------|---------|
| `workflow_sessions` | id (uuid), title, workflow_type (enum), project_id (fk), current_phase (int), total_phases (int), phase_status (enum), title_generating (bool), position (int), done_at, archived_at, timestamps | One row per workflow run |
| `ai_sessions` | id (uuid), workflow_session_id (fk), claude_session_id (string), worktree_path (string), timestamps | ClaudeCode session tracking; 1:N from workflow_sessions |
| `messages` | id (uuid), ai_session_id (fk), role (enum: system/user), content (text), raw_response (map), selected (array), phase (int), timestamps | Chat messages; 1:N from ai_sessions |
| `workflow_session_metadata` | id (uuid), workflow_session_id (fk), phase_name (string), key (string), value (map), timestamps | KV metadata per phase; unique on (ws_id, phase_name, key) |
| `projects` | id (uuid), name, git_repo_url, local_folder, timestamps | Project definitions |
| `oban_jobs` | (standard Oban schema) | Background job queue |

#### 8. Test coverage

**LiveView tests** (integration, 9 files):
- `workflow_type_selection_live_test.exs` — type selection page
- `chore_task_workflow_live_test.exs` — PromptChoreTask flow
- `implement_general_prompt_workflow_live_test.exs` — ImplementGeneralPrompt flow
- `crafting_board_live_test.exs` — session listing
- `archived_sessions_live_test.exs`, `session_archiving_live_test.exs` — archive UI
- `projects_live_test.exs`, `project_inline_creation_live_test.exs` — project CRUD
- `generated_prompt_viewing_live_test.exs` — prompt reuse

**Context tests** (unit, 3 files):
- `workflows_metadata_test.exs` — metadata upsert/get
- `ai_test.exs` — message processing, session action extraction
- `ai/session_test.exs` — AI session management

**Not tested:**
- `AiQueryWorker` — no direct tests for transition logic
- `SetupWorker` / `TitleGenerationWorker` — no tests
- `ClaudeSession` GenServer — no tests
- Phase transition sequences end-to-end — no tests
- Engine/orchestration logic (it doesn't exist as a standalone module)

---

### 1.2 Problem Identification

#### 1. Coupling problems

- **Transition logic in three places:** `WorkflowRunnerLive`, `AiConversationPhase`, and `AiQueryWorker` all contain "what happens next" decisions. Adding a new transition type requires changes in all three.
- **Phase components know about session strategy:** `AiConversationPhase.confirm_advance` checks `session_strategy/2` and calls `ClaudeSession.stop_for_workflow_session` — this is engine-level logic embedded in a UI component.
- **Worker contains UI-level concerns:** `AiQueryWorker.handle_skip_phase` decides whether to enqueue the next worker or let the LiveView handle it — mixing orchestration with job execution.

#### 2. Duplication

- **`phase_name/1` and `phase_columns/0`** are copy-pasted identically in both workflow modules.
- **`total_phases/0`** is `length(phases())` in both — could be derived.
- **Session strategy check + stop + create pattern** appears in both `AiConversationPhase.confirm_advance` and `AiQueryWorker.handle_skip_phase`.
- **Phase opts lookup** (`Enum.at(phases, phase - 1)`) is repeated in `AiQueryWorker`, `AI`, `ClaudeSession`, and `Workflows`.

#### 3. Missing abstractions

- **No Workflow behaviour:** Workflow modules have an implicit contract (must export `phases/0`, `label/0`, etc.) but no `@behaviour` or `use` macro to enforce it. Adding a new workflow means knowing which functions to implement by reading existing modules.
- **No Executor behaviour:** All "conversation" phases use the same `AiConversationPhase` LiveComponent with opts. The difference between interactive chat, non-interactive AI, and form input is controlled by flags (`:non_interactive`, `:final`, `:skippable`) rather than separate executor modules.
- **No Engine module:** Phase transition logic is procedural and scattered, not encapsulated.

#### 4. State management gaps

- **Phase status is workflow-level, not phase-level:** `phase_status` on `workflow_sessions` means only the current phase's status is tracked. There's no record of what status previous phases went through.
- **No phase execution records:** When a phase completes, there's no row recording that it completed, when, or with what result. Phase results are in metadata but there's no structured lifecycle.
- **Race potential in `handle_skip_phase`:** The function reads `ws`, computes `next_phase`, and updates — but another process could advance the phase between read and update. The Oban uniqueness constraint (30s window) partially mitigates this.

#### 5. Scalability issues

- **Adding a new workflow:** Requires: (1) add module, (2) add to `@workflow_modules` map, (3) add to `Session` schema's enum values, (4) write a DB migration to add the new enum value. Steps 3-4 are fragile.
- **Adding a new phase type:** Currently means creating a new LiveComponent. The `render_phase` dispatch is generic enough, but there's no behaviour to implement — you'd need to study `AiConversationPhase` to understand the expected interface.
- **Adding a new interaction mode:** Would require modifying `AiConversationPhase` rather than adding a new executor, since all AI interaction goes through one component.

#### 6. Data model mismatches

- **No separation of definition vs execution for phases:** Phase identity is an integer index into a list. If the phase list changes, existing sessions with `current_phase: 4` may point to a different phase. No phase name is stored on the execution side.
- **Messages linked to `ai_sessions`, not to phases:** To get messages for a specific phase, you filter by the `phase` integer column. If the AI session changes (`:new` strategy), messages are split across AI sessions — hence the need for `list_messages_for_workflow_session`.
- **`phase_status` is overloaded:** `:generating` can mean "Oban worker is running" or "waiting for ClaudeCode response". `:conversing` can mean "waiting for user input" or "non-interactive phase failed and was cancelled".

---

### 1.3 Dependency Map

#### Internal consumers

| Consumer | How it uses workflow code |
|----------|-------------------------|
| `WorkflowRunnerLive` | Mounts phases, handles transitions, renders chrome |
| `AiConversationPhase` | Reads/writes workflow session state, enqueues workers, manages transitions |
| `WizardPhase` | Sends `:phase_complete` with session creation data |
| `PromptWizardPhase` | Same as WizardPhase; also queries `list_sessions_with_generated_prompts` |
| `SetupPhase` | Reads metadata, enqueues `SetupWorker` and `TitleGenerationWorker` |
| `CraftingBoardLive` | Lists workflow sessions, shows status badges |
| `DashboardLive` | Shows workflow session counts/status |
| `ArchivedSessionsLive` | Lists archived sessions |
| `AiQueryWorker` | Reads workflow session, manages phase transitions, creates messages |
| `SetupWorker` | Reads workflow session + project, writes metadata |
| `TitleGenerationWorker` | Updates workflow session title |
| `Destila.AI` context | Message CRUD, session management, response processing |
| `Destila.Workflows` context | Session CRUD, metadata, classification |
| `BoardComponents` | Renders workflow badges and progress indicators |
| `ChatComponents` | Renders chat messages with phase-aware formatting |

#### External integrations

- **ClaudeCode library:** Called via `ClaudeSession` GenServer and `ClaudeCode.query/2`
- **MCP tools (`Destila.AI.Tools`):** AI invokes `ask_user_question` and `session` tools during conversations
- **Git operations (`Destila.Git`):** Called by `SetupWorker` for repo sync and worktree creation

#### Shared state

- `workflow_sessions` table is read by: `CraftingBoardLive`, `DashboardLive`, `ArchivedSessionsLive`, `PromptWizardPhase` (for generated prompts)
- `messages` table is read by: `AiConversationPhase`, `AiQueryWorker`
- `workflow_session_metadata` table is read by: `SetupPhase`, `AiConversationPhase` (for worktree_path), `AiQueryWorker` (for worktree_path), workflow prompt functions

---

## 2. Rewrite vs. Refactor Decision

| Component | Decision | Reasoning |
|-----------|----------|-----------|
| **Workflow definitions** (how workflows are declared) | **A: Keep and Refactor** | Workflows are already in Elixir modules with the right shape. They need a `use MyApp.Workflow` macro to eliminate boilerplate (`total_phases/0`, `phase_name/1`, `phase_columns/0` are copy-pasted) and enforce the contract via a behaviour. The phase tuple format `{Component, opts}` is close to the target DSL's `phase :name, executor: ..., config: %{...}`. Refactor the tuple format into a `phase` macro that accumulates definitions at compile time. |
| **Phase definitions** (how phases are declared) | **A: Keep and Refactor** | Phase configurations already encode the key information (name, system_prompt, interaction flags). Refactor the keyword opts into structured config maps and introduce an executor concept. The LiveComponent references (`DestilaWeb.Phases.AiConversationPhase`) become executor modules; the LiveComponent is chosen based on `executor.interaction_mode()`. |
| **Execution state tracking** (DB tables + schemas) | **B: Wrap and Deprecate** | The `workflow_sessions` table is close but missing per-phase execution tracking. Add a new `phase_executions` table alongside. Keep `workflow_sessions` as-is but stop using `phase_status` for new code — use `phase_executions.status` instead. The `messages` table stays; add `phase_execution_id` FK as optional. Migrate gradually. |
| **Phase transition / engine logic** | **C: Replace Entirely** | Transition logic is scattered across `WorkflowRunnerLive`, `AiConversationPhase`, and `AiQueryWorker` with no tests on the core logic. There's no module to refactor — the abstraction doesn't exist yet. Create `Destila.Executions.Engine` from scratch. It's small enough to write fresh and the scattered code has no safety net. |
| **Interactive phase UI** (LiveView/components) | **A: Keep and Refactor** | `WorkflowRunnerLive` is already a generic orchestrator. `AiConversationPhase` handles both interactive and non-interactive well. Refactor to remove transition logic (move to Engine), keep the rendering and event handling. The component dispatch via `render_phase/1` already works generically. |
| **Async job handling** (Oban workers) | **A: Keep and Refactor** | `AiQueryWorker` works correctly for LLM calls via Oban. Refactor to remove transition logic (`handle_skip_phase`) — the worker should just process the AI call and broadcast the result; the Engine handles what happens next. `SetupWorker` and `TitleGenerationWorker` stay as-is. |
| **Chat/LLM integration** | **A: Keep and Refactor** | `ClaudeSession` GenServer, `AI.Tools` MCP server, and the streaming/collection logic are solid and well-designed. Keep entirely. Extract prompt building and response interpretation into executor modules (currently embedded in workflow modules as `system_prompt` functions). |
| **Form handling** | **N/A — Does not exist yet** | There are no generic form executors. The wizard phases are custom one-off components. If the target requires a `FormExecutor`, it would be a new addition in a later phase. The wizard phases work fine and don't need to become generic forms. |

---

## 3. Existing Code Mapping

```
EXISTING MODULE/FILE                                       → TARGET                                         → STRATEGY
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
lib/destila/workflows.ex                                   → Destila.Workflows (add DSL macro + behaviour)  → Refactor
lib/destila/workflows/prompt_chore_task_workflow.ex         → use Destila.Workflow DSL                       → Refactor
lib/destila/workflows/implement_general_prompt_workflow.ex  → use Destila.Workflow DSL                       → Refactor
lib/destila/workflows/session.ex                           → Keep, add phase_execution association           → Refactor
lib/destila/workflows/session_metadata.ex                  → Keep as-is                                     → Keep
lib/destila/ai.ex                                          → Split: AI context stays, execution bits → Executions → Refactor
lib/destila/ai/session.ex                                  → Keep as-is                                     → Keep
lib/destila/ai/message.ex                                  → Keep, add optional phase_execution_id FK       → Refactor
lib/destila/ai/claude_session.ex                           → Keep as-is                                     → Keep
lib/destila/ai/tools.ex                                    → Keep as-is                                     → Keep
lib/destila/workers/ai_query_worker.ex                     → Remove transition logic, delegate to Engine     → Refactor
lib/destila/workers/setup_worker.ex                        → Keep as-is                                     → Keep
lib/destila/workers/title_generation_worker.ex              → Keep as-is                                     → Keep
lib/destila/pub_sub_helper.ex                              → Keep as-is                                     → Keep
lib/destila/projects.ex                                    → Keep as-is                                     → Keep
lib/destila_web/live/workflow_runner_live.ex                → Remove transition logic, subscribe per-execution → Refactor
lib/destila_web/live/phases/ai_conversation_phase.ex       → Remove transition logic, keep rendering         → Refactor
lib/destila_web/live/phases/wizard_phase.ex                → Keep as-is                                     → Keep
lib/destila_web/live/phases/prompt_wizard_phase.ex          → Keep as-is                                     → Keep
lib/destila_web/live/phases/setup_phase.ex                 → Keep as-is                                     → Keep
lib/destila_web/live/crafting_board_live.ex                → Keep as-is                                     → Keep
lib/destila_web/live/dashboard_live.ex                     → Keep as-is                                     → Keep
lib/destila_web/live/archived_sessions_live.ex             → Keep as-is                                     → Keep
lib/destila_web/components/chat_components.ex              → Keep as-is                                     → Keep
lib/destila_web/components/board_components.ex             → Keep as-is                                     → Keep
— (new)                                                    → Destila.Workflow (behaviour + DSL macro)        → New
— (new)                                                    → Destila.Executions (context module)             → New
— (new)                                                    → Destila.Executions.Engine                       → New
— (new)                                                    → Destila.Executions.PhaseExecution (schema)      → New
— (new)                                                    → migration: create phase_executions table        → New
```

---

## 4. Implementation Phases

### Phase 1: Workflow DSL + Behaviour (no behavior change)

**Goal:** Eliminate boilerplate in workflow modules, enforce the contract, add a registry.

**Changes:**

1. **Create `lib/destila/workflow.ex`** — a `use` macro + behaviour:
   ```elixir
   defmodule Destila.Workflow do
     @callback phases() :: [phase_definition()]
     @callback label() :: String.t()
     @callback description() :: String.t()
     @callback icon() :: String.t()
     @callback icon_class() :: String.t()
     @callback default_title() :: String.t()
     @callback completion_message() :: String.t()
     @callback session_strategy(integer()) :: :resume | :new | {:resume, keyword()} | {:new, keyword()}

     defmacro __using__(_opts) do
       quote do
         @behaviour Destila.Workflow

         # Default implementations for common functions
         def total_phases, do: length(phases())

         def phase_name(phase) when is_integer(phase) do
           case Enum.at(phases(), phase - 1) do
             {_mod, opts} -> Keyword.get(opts, :name)
             nil -> nil
           end
         end
         def phase_name(_), do: nil

         def phase_columns do
           columns =
             1..total_phases()
             |> Enum.map(fn n -> {n, phase_name(n)} end)
             |> Enum.reject(fn {_, name} -> is_nil(name) end)
           columns ++ [{:done, "Done"}]
         end

         def session_strategy(_phase), do: :resume

         defoverridable [total_phases: 0, phase_name: 1, phase_columns: 0, session_strategy: 1]
       end
     end
   end
   ```

2. **Refactor both workflow modules** to `use Destila.Workflow`:
   - Remove copy-pasted `total_phases/0`, `phase_name/1`, `phase_columns/0`
   - Keep `phases/0`, `label/0`, `description/0`, `icon/0`, `icon_class/0`, `default_title/0`, `completion_message/0`
   - Override `session_strategy/1` only in `ImplementGeneralPromptWorkflow`

3. **Add auto-registration** in the `Destila.Workflows` dispatcher:
   - Replace the hardcoded `@workflow_modules` map with compile-time module attribute that discovers all modules using `Destila.Workflow`
   - Or keep the explicit map for now (simpler, no magic) and just validate at compile time that each module implements the behaviour

4. **Verify:** Existing tests pass, app compiles, all workflows work identically.

**Files changed:**
- New: `lib/destila/workflow.ex`
- Modified: `lib/destila/workflows/prompt_chore_task_workflow.ex`
- Modified: `lib/destila/workflows/implement_general_prompt_workflow.ex`
- Modified: `lib/destila/workflows.ex` (optional: remove delegated functions that now come from modules)

**Tests:**
- Run existing test suite — all should pass with no changes

---

### Phase 2: Phase Executions Table (data model foundation)

**Goal:** Add per-phase execution tracking without changing any behavior.

**Changes:**

1. **Create migration: `create_phase_executions`**
   ```elixir
   create table(:phase_executions, primary_key: false) do
     add :id, :binary_id, primary_key: true
     add :workflow_session_id, references(:workflow_sessions, type: :binary_id, on_delete: :delete_all), null: false
     add :phase_number, :integer, null: false
     add :phase_name, :string, null: false
     add :status, :string, null: false, default: "pending"
     # pending | awaiting_input | processing | awaiting_confirmation | completed | skipped | failed
     add :result, :map
     add :staged_result, :map
     add :started_at, :utc_datetime
     add :completed_at, :utc_datetime

     timestamps(type: :utc_datetime)
   end

   create index(:phase_executions, [:workflow_session_id])
   create unique_index(:phase_executions, [:workflow_session_id, :phase_number])
   ```

2. **Create `lib/destila/executions/phase_execution.ex`** — Ecto schema

3. **Add optional `phase_execution_id` FK to `messages` table** (nullable, so existing messages don't break)

4. **Do NOT write to these tables yet** — this phase only creates them.

**Files changed:**
- New: `priv/repo/migrations/YYYYMMDDHHMMSS_create_phase_executions.exs`
- New: `lib/destila/executions/phase_execution.ex`
- Modified: `priv/repo/migrations/YYYYMMDDHHMMSS_add_phase_execution_id_to_messages.exs` (new migration)
- Modified: `lib/destila/ai/message.ex` (add optional `belongs_to :phase_execution`)

**Tests:**
- Migration runs cleanly, existing tests pass

---

### Phase 3: Executions Context + Engine (parallel path)

**Goal:** Build the orchestration layer that can run a workflow from start to finish.

**Changes:**

1. **Create `lib/destila/executions.ex`** — context module:
   ```elixir
   defmodule Destila.Executions do
     # Queries
     def get_phase_execution!(id)
     def get_current_phase_execution(workflow_session_id)
     def list_phase_executions(workflow_session_id)

     # Mutations
     def create_phase_execution(workflow_session, phase_number, attrs)
     def update_phase_execution_status(phase_execution, status, attrs \\ %{})
     def complete_phase(phase_execution, result)
     def stage_completion(phase_execution, result)
     def confirm_completion(phase_execution)
     def reject_completion(phase_execution)
     def skip_phase(phase_execution, reason)
   end
   ```

2. **Create `lib/destila/executions/engine.ex`**:
   ```elixir
   defmodule Destila.Executions.Engine do
     def advance_to_next(workflow_session) do
       # 1. Reload from DB
       # 2. Resolve workflow module
       # 3. Find next phase
       # 4. If none → complete workflow
       # 5. If skip_when → skip and recurse
       # 6. If non-interactive → create processing phase_execution, enqueue worker
       # 7. If interactive → create awaiting_input phase_execution, broadcast
     end

     def handle_phase_result(phase_execution, result) do
       # Called by AiQueryWorker after AI responds
       # Delegates to the right action based on result type
     end
   end
   ```

3. **Wire `AiQueryWorker` to use Engine:**
   - After processing AI response, call `Engine.handle_phase_result/2` instead of inline transition logic
   - Keep the existing `handle_skip_phase` as a fallback during migration (guarded by whether a `phase_execution` exists)

4. **Write Engine to be backwards-compatible:**
   - If no `phase_execution` exists for the current phase, create one on-the-fly
   - Engine reads `phase_status` from `workflow_sessions` to stay in sync with old code
   - Engine writes to both `phase_executions` AND `workflow_sessions.phase_status` during transition period

**Files changed:**
- New: `lib/destila/executions.ex`
- New: `lib/destila/executions/engine.ex`
- Modified: `lib/destila/workers/ai_query_worker.ex`

**Tests:**
- New: `test/destila/executions_test.exs` — context unit tests
- New: `test/destila/executions/engine_test.exs` — engine transition tests
- Existing tests continue to pass

---

### Phase 4: UI Migration (wire LiveView to Engine)

**Goal:** Remove transition logic from LiveView and components; delegate to Engine.

**Changes:**

1. **Refactor `AiConversationPhase`:**
   - `confirm_advance` → calls `Engine.advance_to_next(ws)` instead of inline logic
   - `decline_advance` → calls `Executions.reject_completion(phase_execution)` + updates workflow session
   - Remove session strategy checks and `ClaudeSession.stop_for_workflow_session` calls
   - Keep all rendering and chat event handling

2. **Refactor `WorkflowRunnerLive`:**
   - `handle_info({:phase_complete, ...})` → calls `Engine.advance_to_next(ws)` for the non-wizard case
   - Keep wizard session creation logic (it's specific to the wizard phase type)
   - Subscribe to `"execution:#{ws.id}"` topic in addition to `"store:updates"` (eventually replace)

3. **Add Engine PubSub broadcasts:**
   - Engine broadcasts on `"execution:#{ws.id}"` for phase transitions
   - Also broadcasts on `"store:updates"` for backwards compatibility with `CraftingBoardLive` etc.

**Files changed:**
- Modified: `lib/destila_web/live/phases/ai_conversation_phase.ex`
- Modified: `lib/destila_web/live/workflow_runner_live.ex`
- Modified: `lib/destila/executions/engine.ex` (add PubSub)

**Tests:**
- Existing LiveView tests should pass (behavior unchanged from user perspective)
- May need minor test adjustments for new PubSub topic

---

### Phase 5: Cleanup + Consolidation

**Goal:** Remove old transition code paths, consolidate state.

**Changes:**

1. **Remove `handle_skip_phase` from `AiQueryWorker`** — all transitions go through Engine
2. **Remove transition logic from `AiConversationPhase`** — session strategy checks, stop/create session calls
3. **Consider deprecating `phase_status` on `workflow_sessions`:**
   - Can be derived from the latest `phase_execution.status`
   - Keep the column but stop writing to it from new code
   - Update `classify/1` to check `phase_executions` first, fall back to `phase_status`
4. **Migrate existing sessions:** Write a Mix task that backfills `phase_executions` for in-progress sessions
5. **Remove old code paths** that check for absence of `phase_execution`

**Files changed:**
- Modified: `lib/destila/workers/ai_query_worker.ex` (remove `handle_skip_phase`)
- Modified: `lib/destila_web/live/phases/ai_conversation_phase.ex` (remove engine logic)
- Modified: `lib/destila/workflows.ex` (update `classify/1`)
- New: `lib/mix/tasks/backfill_phase_executions.ex` (optional data migration)

---

## 5. Integration Checklist

- [x] **Audit document completed** — sections 1.1, 1.2, 1.3 above
- [x] **Rewrite/refactor decision table completed** — section 2 above
- [x] **Existing code mapping completed** — section 3 above
- [x] **Existing user schema identified** — no `users` table; auth is session-based via `RequireAuth` plug. No user FK on `workflow_sessions` (single-user app).
- [x] **PubSub module:** `Destila.PubSub`, topic `"store:updates"`
- [x] **Oban status:** Engine `Oban.Engines.Lite` (SQLite), queues: `default: 2`, `setup: 1`. Will need to add `:workflows` queue for automatic phase worker if separating from `:default`.
- [x] **LLM client:** `ClaudeCode` library via `Destila.AI.ClaudeSession` GenServer
- [x] **Router auth pipeline:** `:require_auth` (plug `DestilaWeb.Plugs.RequireAuth`)
- [x] **LiveView layout:** `DestilaWeb.Layouts` (`:root` and `:app`)
- [x] **Context naming:** `Destila.Workflows`, `Destila.AI`, `Destila.Projects` — new context will be `Destila.Executions`
- [x] **Primary key type:** `:binary_id` (UUID) everywhere
- [x] **Data migration plan:** Phase executions backfill via Mix task (Phase 5); no table drops needed

---

## 6. Key Design Principles Applied to This Codebase

1. **Workflows are already code** — the existing system correctly puts definitions in modules, not the DB. The refactoring adds structure (DSL macro, behaviour) but doesn't change the fundamental approach.
2. **Executors as a concept don't exist yet** — the current system uses LiveComponent + opts flags. The migration path is: extract prompt-building and response-interpretation into executor-like modules, keep LiveComponents as renderers.
3. **The Engine is the biggest gap** — creating `Executions.Engine` is the most impactful change. It consolidates scattered transition logic into one testable module.
4. **Phase executions fill the data model gap** — adding per-phase tracking enables proper lifecycle management and makes the system observable.
5. **Never break the running app** — every phase above is independently deployable. The Engine runs alongside old code before taking over.

---

## 7. Risk Assessment

| Risk | Mitigation |
|------|-----------|
| Engine introduces regressions in phase transitions | Write comprehensive Engine tests before wiring to UI; keep old code paths as fallback during Phase 3-4 |
| Dual-write to `workflow_sessions.phase_status` AND `phase_executions.status` causes inconsistency | Engine is the single writer during transition; old reads still work because Engine updates both |
| Existing tests break during refactoring | Run full test suite after each phase; phases are designed to be individually merge-safe |
| ClaudeCode session lifecycle disrupted by Engine changes | Engine delegates session management to existing `ClaudeSession` module; no changes to GenServer |
| New `phase_executions` table adds query overhead | Indexed on `workflow_session_id`; queries are simple FK lookups; SQLite handles this fine for single-user app |
