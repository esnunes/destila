# Implementation Prompts

Each prompt below is self-contained. Hand it to an agent as-is.

---

## F1 — Ecto.Enum for PhaseExecution.status

**Task:** Convert `phase_executions.status` from a plain string to an `Ecto.Enum`.

**Context:** `Destila.Executions.PhaseExecution` (`lib/destila/executions/phase_execution.ex`) stores `status` as `:string` with a `@statuses` list for validation. All consumers pattern-match on string literals like `"processing"`, `"awaiting_input"`, etc. Meanwhile, `Destila.Workflows.Session` already uses `Ecto.Enum` for its `phase_status` field.

**What to do:**

1. In `lib/destila/executions/phase_execution.ex`:
   - Change `field(:status, :string, default: "pending")` to `field(:status, Ecto.Enum, values: [:pending, :processing, :awaiting_input, :awaiting_confirmation, :completed, :skipped, :failed], default: :pending)`
   - Remove the `@statuses` module attribute and `validate_inclusion(:status, @statuses)` from changeset
   - Remove the `def statuses` function

2. Since this is SQLite and Ecto.Enum stores atoms as strings in the DB, no column migration is needed.

3. Update all pattern matches from strings to atoms in: `lib/destila/executions/engine.ex`, `lib/destila/executions.ex`, `lib/destila_web/live/workflow_runner_live.ex`. Change `"pending"` to `:pending`, `"processing"` to `:processing`, etc.

4. Search the entire codebase for remaining string status references and update.

5. Run `mix precommit`.

**Done when:** All phase execution status values are atoms throughout the codebase. Tests pass.

---

## F2 — Explicit phase execution state machine

**Task:** Create `Destila.Executions.StateMachine` module with validated transitions. Migrate all Engine status writes to use it.

**Context:** The phase execution state machine is implicit — scattered across `Destila.Executions.Engine` and `Destila.Executions`. No single place shows valid transitions.

**Prerequisite:** F1 must be done first.

**What to do:**

1. Create `lib/destila/executions/state_machine.ex` with:
   - A `@transitions` map defining valid transitions (see report2.md for the full map)
   - `valid_transition?(from, to)` function
   - `transition!(%PhaseExecution{} = pe, to, attrs \\ %{})` that validates then updates via Repo

2. In `lib/destila/executions/engine.ex`, replace all `Executions.update_phase_execution_status/2-3`, `Executions.start_phase/2`, `Executions.complete_phase/1-2`, `Executions.stage_completion/2`, `Executions.reject_completion/1` with `StateMachine.transition!/3`.

3. Also update `lib/destila_web/live/workflow_runner_live.ex` where `decline_advance` calls `Executions.reject_completion`.

4. Run `mix precommit`.

**Done when:** A `StateMachine` module exists. All status writes go through validated transitions. Invalid transitions raise `ArgumentError`. Tests pass.

---

## F3 — Eliminate phase_status from workflow_sessions

**Task:** Remove `phase_status` column from `workflow_sessions`. Derive status from the latest `phase_execution` record.

**Prerequisite:** F1 and F2 must be done.

**What to do:**

1. Add `Executions.current_status/1` that derives status from the latest phase execution.
2. Add `Session.phase_status/1` function that calls through to `Executions.current_status/1`.
3. Remove `field(:phase_status, ...)` from the Session schema and changeset.
4. Remove all `Workflows.update_workflow_session(ws, %{phase_status: ...})` calls from the Engine (~6 places).
5. Update `Workflows.classify/1` and all LiveView/component references to use `Session.phase_status/1`.
6. Create migration to remove the column.
7. Run `mix precommit`.

**Done when:** The `phase_status` column is gone. All status reads derive from `phase_executions`. Tests pass.

---

## F4 — Messages FK directly to workflow_sessions

**Task:** Add `workflow_session_id` column to `messages` table. Simplify message queries.

**What to do:**

1. Create migration: add `workflow_session_id` to messages, backfill from ai_sessions join, add index.
2. Update `Destila.AI.Message` schema: add `belongs_to :workflow_session`, add to changeset cast.
3. Simplify `AI.list_messages_for_workflow_session/1` to query directly without join.
4. Update `AI.create_message/2` and its callers in `AI.Conversation` to pass `workflow_session_id`.
5. Keep `ai_session_id` for provenance.
6. Run `mix precommit`.

**Done when:** Messages have direct FK to workflow_sessions. No join through ai_sessions needed for listing. Tests pass.

---

## S1 — Extract AI.ResponseProcessor

**Task:** Move all response processing logic from `Destila.AI` into `Destila.AI.ResponseProcessor`.

**What to do:**

1. Create `lib/destila/ai/response_processor.ex`.
2. Move from `lib/destila/ai.ex`: `process_message/2`, `extract_session_action/1`, `derive_message_type/4`, `extract_tool_input/1`, `extract_questions/1`, `parse_questions/2`, `response_text/1`, `access/2`, and `@session_tool_names`.
3. Update callers: `lib/destila/ai/conversation.ex` (calls `AI.response_text`, `AI.extract_session_action`), `lib/destila_web/live/workflow_runner_live.ex` (calls `AI.process_message`).
4. Run `mix precommit`.

**Done when:** `Destila.AI` is a thin CRUD module. All processing lives in `ResponseProcessor`. Tests pass.

---

## ~~S2 — Dropped~~

No longer needed. After W1a and W1b, all infrastructure metadata is eliminated.

---

## S3 — Move session_opts_for_workflow out of ClaudeSession

**Task:** Move `session_opts_for_workflow/3` and `merge_phase_opts/2` from ClaudeSession to a new `Destila.AI.SessionConfig` module.

**What to do:**

1. Create `lib/destila/ai/session_config.ex`.
2. Move the two functions from `lib/destila/ai/claude_session.ex` (lines 149-206).
3. Update `lib/destila/workers/ai_query_worker.ex` to call `SessionConfig` instead.
4. Run `mix precommit`.

**Done when:** ClaudeSession has no references to `Workflows.phases/1` or `AI.get_ai_session_for_workflow/1`. Tests pass.

---

## S4 — Plugin management at application boot

**Task:** Move plugin setup from `ClaudeSession.init/1` to a `Destila.AI.PluginManager` module that runs once at boot.

**What to do:**

1. Create `lib/destila/ai/plugin_manager.ex` with `setup!/0` that runs the marketplace/install/enable cycle and caches `plugin_paths` in `:persistent_term`.
2. Call `PluginManager.setup!/0` from `Application.start/2` after supervision tree starts.
3. In `ClaudeSession.init/1`, remove the plugin `with` chain and `plugin_cmd/3`. Replace with `Keyword.put(claude_opts, :plugins, PluginManager.plugin_paths())`.
4. Run `mix precommit`.

**Done when:** Plugins installed once at boot. No plugin commands per-session. Tests pass.

---

## W1a — Title generation as fire-and-forget

**Task:** Decouple title generation from setup coordination. Remove all `title_gen` metadata.

**Context:** `TitleGenerationWorker` currently writes `title_gen` metadata and calls `Engine.phase_update` with `setup_step_completed`. The `title_generating` boolean on `workflow_sessions` already tracks this.

**What to do:**

1. In `lib/destila/workers/title_generation_worker.ex`: remove `upsert_metadata` calls (lines 16-18, 31-33) and `Engine.phase_update` call (lines 35-39). Worker only generates title, updates session, returns `:ok`.
2. In `lib/destila/workflows.ex` `create_workflow_session/1`: enqueue `TitleGenerationWorker` directly instead of going through `Setup.start/1`.
3. In `lib/destila/workflows/setup.ex`: remove title generation enqueue from `start/1`, remove `"title_gen"` from `@setup_keys`.
4. Run `mix precommit`.

**Done when:** Title generation writes no metadata, has no Engine callback, doesn't participate in setup coordination. Tests pass.

---

## W1b — Worktree preparation as a re-runnable precondition

**Task:** Engine checks worktree availability before each phase, preparing if needed. Delete `Workflows.Setup`. Remove all infrastructure metadata.

**Context:** `PrepareWorkflowSession` does the git work. `Workflows.Setup` coordinates by polling metadata. Worktree path already lives on `ai_sessions.worktree_path`.

**Prerequisite:** W1a done. F2 helpful.

**What to do:**

1. In Engine, add `ensure_worktree_ready/1` that checks `ai_session.worktree_path` + `Git.worktree_exists?`. If not ready, enqueue `PrepareWorkflowSession`.
2. In `PrepareWorkflowSession`: remove ALL `upsert_step/5` calls and the `upsert_step` function. Store worktree path on `ai_sessions.worktree_path`. Signal completion with `%{worktree_ready: true}`.
3. In Engine, handle `worktree_ready` callback to start the waiting phase.
4. In `Workflows.create_workflow_session`: call `Engine.start_session` directly instead of `Setup.start`.
5. Delete `lib/destila/workflows/setup.ex`.
6. Update all worktree path reads from metadata to `ai_session.worktree_path` (in `AI.Conversation`, `WorkflowRunnerLive`, `ImplementGeneralPromptWorkflow`).
7. Update `setup_components.ex` for simplified progress display.
8. Run `mix precommit`.

**Done when:** `Workflows.Setup` deleted. No infrastructure metadata remains. Worktree checked before each phase. Tests pass.

---

## W2 — Framework-driven metadata export

**Task:** Replace `handle_response/3` callback with declarative `export_as` field on `Phase`.

**What to do:**

1. Add `export_as: nil` to `Phase` struct in `lib/destila/workflows/phase.ex`.
2. In `BrainstormIdeaWorkflow`: add `export_as: "prompt_generated"` to Prompt Generation phase. Delete `handle_response/3`.
3. In `AI.Conversation.phase_update/2`: after saving AI result, check `phase_def.export_as`. If set, auto-export.
4. Remove `handle_response/3` from `Workflow` behaviour and `__using__` macro.
5. Run `mix precommit`.

**Done when:** `export_as` field drives automatic metadata export. `handle_response/3` no longer exists. Tests pass.

---

## W3 — AI provider behaviour

**Task:** Define `Destila.AI.Provider` behaviour. Make `ClaudeSession` implement it.

**Prerequisite:** S3 done.

**What to do:**

1. Create `lib/destila/ai/provider.ex` with callbacks: `for_session/2`, `query_streaming/3`, `stop/1`, `stop_for_session/1`.
2. Add `@behaviour Destila.AI.Provider` to `ClaudeSession`.
3. Add config: `config :destila, :ai_provider, Destila.AI.ClaudeSession`.
4. Update callers (`AiQueryWorker`, Engine, `Workflows`, `WorkflowRunnerLive`) to use configured provider.
5. Run `mix precommit`.

**Done when:** Provider behaviour exists. ClaudeSession implements it. Callers use config. Tests pass.

---

## W4 — Standardize Engine return types

**Task:** All Engine public functions return `{:ok, updated_ws}`. Remove redundant DB re-fetches from callers.

**Prerequisite:** F3 done.

**What to do:**

1. Update each Engine function to explicitly return `{:ok, ws}`.
2. In `WorkflowRunnerLive`, use returned session directly instead of calling `get_workflow_session!` after each Engine call (~8 removals).
3. Run `mix precommit`.

**Done when:** Consistent returns. No redundant re-fetches. Tests pass.

---

## W5 — Session as a `gen_statem` process

**Task:** Replace `Destila.Executions.Engine` with a `Destila.Sessions.SessionProcess` `gen_statem`. All user interaction flows through it. WorkflowRunnerLive communicates exclusively through SessionProcess for domain events.

**Prerequisites:** F1, F2, F3, W4 done. W1b recommended.

**Interaction pattern:**

- User actions (send message, confirm, decline, retry, cancel) → synchronous `call` returning `{:ok, ws}`
- Worker results (AI response, worktree ready) → async `cast`
- AI streaming → bypasses SessionProcess (display concern, broadcasts directly to LiveView)
- SessionProcess broadcasts `{:status_changed, ws_id, status}` and `{:message_added, ws_id, msg}` via PubSub
- LiveView updates incrementally from PubSub (appends messages, no full reload)

**What to do:**

1. Create `lib/destila/sessions/session_process.ex` with `gen_statem` `:handle_event_function` callback mode.

2. Client API: `send_message/2`, `confirm_advance/1`, `decline_advance/1`, `retry/1`, `cancel/1`, `mark_done/1`, `mark_undone/1` — thin wrappers around `call/cast`.

3. Map Engine functions to `handle_event` clauses:
   - `{:phase, N, :awaiting_input}` + `{:call, {:user_message, content}}` → save message, enqueue worker, transition to `:processing`, reply `{:ok, ws}`
   - `{:phase, N, :processing}` + `{:cast, {:ai_response, result}}` → save AI message, check action, transition accordingly, broadcast
   - `{:phase, N, :awaiting_confirmation}` + `{:call, :confirm_advance}` → complete phase, advance, reply
   - `{:phase, N, :awaiting_confirmation}` + `{:call, :decline_advance}` → transition to `:awaiting_input`, reply
   - `{:phase, N, _}` + `{:call, :retry}` → stop AI session, restart phase, reply
   - `{:phase, N, :processing}` + `{:call, :cancel}` → stop AI session, transition to `:awaiting_input`, reply
   - `{:cast, :worktree_ready}` in `:preparing` → start phase
   - `:state_timeout` → `{:stop, :normal}`

4. State reconstruction from DB: `reconstruct_state/1` reads `workflow_sessions.current_phase` + latest `phase_execution.status`.

5. Process lifecycle: start on demand via `ensure_started/1`, registered in `Destila.Sessions.Registry`, hibernates after 5min, terminates after 30min.

6. Add to supervision tree: `{Registry, keys: :unique, name: Destila.Sessions.Registry}` and `{DynamicSupervisor, name: Destila.Sessions.Supervisor}`.

7. Update LiveView event handlers to call SessionProcess:
   ```elixir
   def handle_event("send_text", %{"content" => c}, socket) when c != "" do
     {:ok, ws} = SessionProcess.send_message(socket.assigns.workflow_session.id, c)
     {:noreply, assign(socket, :workflow_session, ws)}
   end
   ```

8. Update LiveView PubSub handlers for incremental updates:
   - `{:message_added, {ws_id, msg}}` → append to messages list
   - `{:status_changed, {ws_id, status}}` → refresh session and derived state

9. What stays in LiveView: rendering, question_answers accumulation, title editing, streaming display.

10. Update workers: `AiQueryWorker` → `SessionProcess.cast(ws_id, {:ai_response, result})`. `PrepareWorkflowSession` → `SessionProcess.cast(ws_id, :worktree_ready)`.

11. Update `Workflows.create_workflow_session` → `SessionProcess.ensure_started(ws.id)`.

12. Delete `lib/destila/executions/engine.ex`.

13. Run `mix precommit`.

**Done when:** Engine deleted. SessionProcess handles all state transitions. LiveView communicates through SessionProcess client API. Workers cast to SessionProcess. Sessions start on demand, reconstruct from DB. Tests pass.

---

## U1 — Centralized aliveness tracker

**Task:** Create `Destila.AI.AlivenessTracker` GenServer with ETS + PubSub. Remove process monitoring from LiveViews.

**What to do:**

1. Create `lib/destila/ai/aliveness_tracker.ex`: GenServer that monitors AI session processes via Registry, maintains ETS table `session_id -> boolean`, broadcasts `{:aliveness_changed, session_id, alive?}`.
2. Add to supervision tree before `DestilaWeb.Endpoint`.
3. Expose `alive?/1` that reads from ETS.
4. Strip all `Process.monitor` / `{:DOWN, ...}` / `alive_sessions` / `monitored_refs` code from `CraftingBoardLive` (~30 lines) and `WorkflowRunnerLive` (~20 lines).
5. LiveViews subscribe to `AlivenessTracker.topic()` and handle `{:aliveness_changed, ...}`.
6. Run `mix precommit`.

**Done when:** Centralized monitoring. No `Process.monitor` in LiveViews. Tests pass.

---

## U2 — SQL-level classification for the Crafting Board

**Task:** Push session classification into database queries.

**Prerequisite:** F3 done (status derived from phase_executions).

**What to do:**

1. Add `Workflows.list_workflow_sessions_with_status/0` that joins with latest phase execution and returns `{session, status}` tuples.
2. Update `CraftingBoardLive` to use the new function instead of loading all + classifying in Elixir.
3. Run `mix precommit`.

**Done when:** Classification happens in SQL. Tests pass.

---

## H1 — Explicit error on nil AI session

**Task:** Log a warning when AI session is nil during phase_update.

**What to do:**

1. In `lib/destila/ai/conversation.ex`, add `require Logger` and log a warning in each `phase_update/2` clause where `ai_session` is nil.
2. Run `mix precommit`.

**Done when:** Nil AI session logs a warning. Tests pass.

---

## H2 — Normalize atom/string keys at the stream boundary

**Task:** Normalize all keys to strings in ClaudeSession stream collector. Remove the dual-key `access/2` helper.

**What to do:**

1. In `ClaudeSession.collect_with_mcp_and_broadcast/2`, normalize mcp_tool_uses to string-keyed maps before returning.
2. Update `extract_session_action/1` to only handle string keys — remove the atom-key clause.
3. Update `response_text/1` for string keys.
4. Remove the `access/2` helper.
5. Run `mix precommit`.

**Done when:** All stream results are string-keyed. No dual-key helper needed. Tests pass.
