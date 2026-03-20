---
title: "feat: Add Chore/Task workflow with AI-driven phases"
type: feat
date: 2026-03-20
---

# feat: Add Chore/Task Workflow with AI-Driven Phases

## Overview

Add a third workflow type — `:chore_task` — for straightforward coding tasks. Unlike the existing static workflows (Feature Request, Project), Chore/Task uses AI-driven conversational phases where the AI dynamically asks questions, suggests advancing, and the user confirms. Also make repo URL mandatory for non-project workflows.

**Brainstorm:** `docs/brainstorms/2026-03-19-chore-task-workflow-brainstorm.md`

## Problem Statement / Motivation

Feature Request and Project workflows use static, predetermined questions that can't adapt to context. For simple implementation tasks (bug fixes, refactors, straightforward features), users need a lighter workflow where the AI guides a natural conversation through clarification, technical approach, Gherkin review, and prompt generation — without rigid step-by-step forms.

## Proposed Solution

1. Add `:chore_task` as a new workflow type throughout the codebase
2. Make repo URL mandatory for all types except `:project`
3. Build an AI-driven phase system in `PromptDetailLive` that coexists with the existing static step system
4. Define 4 phases for Chore/Task: Task Description → Technical Concerns → Gherkin Review → Prompt Generation

## Technical Approach

### Architecture: Branching in PromptDetailLive

The core design decision is how `PromptDetailLive` handles both static and AI-driven workflows. The approach:

- **Static workflows** (`:feature_request`, `:project`): Existing code path unchanged. `handle_user_response/3` looks up next step from `Workflows.steps/1`.
- **AI-driven workflows** (`:chore_task`): New code path. User messages go to the AI session asynchronously. AI responses arrive via `handle_info`. Phase transitions are driven by AI signals.

Branching happens in the event handlers: `handle_event("send_text", ...)` checks `prompt.workflow_type` and dispatches to either `handle_static_response/3` (renamed from current `handle_user_response/3`) or `handle_ai_response/3`.

### Phase Tracking

Reuse existing `steps_completed` and `steps_total` fields on the prompt map:
- `steps_total` = 4 (the 4 phases)
- `steps_completed` = current phase number (1-4, incremented on phase advance)
- This keeps the progress bar, board cards, and all existing UI working without changes

Add a new field `phase_status` on the prompt:
- `:conversing` — normal AI conversation within the current phase
- `:advance_suggested` — AI has suggested advancing; waiting for user confirmation
- `:generating` — AI is processing a response (used for typing indicator)
- `nil` — not an AI-driven workflow (static workflows)

### Message Tagging

Reuse the existing `step` field on messages to mean "phase number" for chore_task. All messages within Phase 2 have `step: 2`, etc. This enables filtering messages by phase if needed.

Add a new field `message_type` on messages (defaults to `nil` for backward compat):
- `nil` — regular message (backward compatible with static workflows)
- `:phase_advance` — AI's suggestion to advance phases (renders with confirmation buttons)
- `:phase_divider` — system-inserted phase header (e.g., "Phase 2: Technical Concerns")
- `:generated_prompt` — the final implementation prompt in Phase 4

### AI Response Flow

```
User types message
  → handle_event("send_text") detects AI-driven workflow
  → Adds user message to Store
  → Sets phase_status: :generating on prompt
  → Spawns Task under TaskSupervisor to call AI.Session.query/2
  → Task completes:
    → Parses AI response for phase-advance signal
    → Adds AI message to Store (with message_type if applicable)
    → Updates prompt phase_status (:conversing or :advance_suggested)
    → PubSub broadcast triggers LiveView update
```

### Phase Advance Signal

The AI's system prompt instructs it to end its message with `<<READY_TO_ADVANCE>>` when it believes the current phase has sufficient clarity. The response handler:
1. Strips the marker from the message content
2. Stores the message with `message_type: :phase_advance`
3. Sets `phase_status: :advance_suggested` on the prompt

The chat UI renders `:phase_advance` messages with two buttons:
- "Continue to Phase N" → advances `steps_completed`, inserts a `:phase_divider` message, resets `phase_status` to `:conversing`
- "I have more to add" → resets `phase_status` to `:conversing`, AI continues chatting

### Phase 3: Gherkin Review — Repo Access

The ClaudeCode session has filesystem and tool access. The phase system prompt instructs the AI to use its tools to clone/browse the repo at the URL stored on the prompt. If no `.feature` files exist, the AI asks if the user wants to create new ones. If the AI determines no Gherkin changes are needed, it sends `<<SKIP_PHASE>>` which auto-advances without user confirmation.

### Phase 4: Prompt Generation & Completion

The AI generates an implementation-ready prompt. The message is stored with `message_type: :generated_prompt`. A "Mark as Done" button appears in the header (similar to "Send to Implementation"). The user can continue chatting to refine the prompt — each refinement re-generates and replaces the `generated_prompt` message. When the user clicks "Mark as Done":
- `column` moves to `:done`
- `steps_completed` = `steps_total` (4)
- The "Send to Implementation" button appears as usual

### Session Timeout & Resumption

The AI session auto-terminates after 5 minutes of inactivity. When the user returns:
1. `PromptDetailLive` mounts, detects `ai_session` PID is dead (via `Process.alive?/1`)
2. Starts a new `AI.Session`
3. Builds a context summary from existing messages grouped by phase
4. Sends the summary as the first message to the new session
5. Updates the prompt's `ai_session` field

**Note:** Per CLAUDE.md test guidelines, avoid `Process.alive?/1` in tests. In production code it's acceptable for this detection logic. For tests, use `Process.monitor/1`.

### Typing Indicator

Add a new `chat_typing_indicator` component in `ChatComponents`. Rendered when `phase_status == :generating`. Shows animated dots in the AI avatar style.

### Input Disabling

Disable the text input and show "AI is thinking..." placeholder when `phase_status == :generating`. Prevents duplicate messages during AI processing.

## Implementation Phases

### Phase 1: Foundation — Register `:chore_task` Type Everywhere

Add the new type to all pattern-matched functions so the app doesn't crash when encountering a chore_task prompt. No behavioral changes yet.

#### Tasks

- [x] `lib/destila/workflows.ex`: Add `steps(:chore_task)` returning a single placeholder step (Phase 1's opening question), `total_steps(:chore_task)` returning `4`, and `completion_message(:chore_task)`
- [x] `lib/destila/ai.ex:63-64`: Add `workflow_type_label(:chore_task)` returning `"chore/task"`
- [x] `lib/destila_web/components/board_components.ex:116-120`: Add `workflow_label(:chore_task)` returning `"Chore/Task"` and `workflow_badge_class(:chore_task)` returning `"badge-warning"`
- [x] `lib/destila_web/live/new_prompt_live.ex:149-150`: Add `default_title(:chore_task)` returning `"New Chore/Task"`
- [x] `lib/destila/seeds.ex`: Add seed chore_task prompts (one in request column, one in distill column)

#### Success Criteria
- [ ] App compiles with no warnings about missing function clauses
- [ ] Board renders chore_task seed cards with amber "Chore/Task" badge

### Phase 2: Wizard Updates

Update the 3-step wizard to support the third workflow type and mandatory repo URL.

#### Tasks

- [x] `lib/destila_web/live/new_prompt_live.ex` template Step 1 (lines 203-231): Add third card for Chore/Task with `hero-wrench-screwdriver` icon and description "Straightforward coding tasks, bug fixes, or refactors"
- [x] `lib/destila_web/live/new_prompt_live.ex` template Step 2 (lines 234-270): Conditionally hide the "Skip" button when `@workflow_type != :project`. Update subtitle text: show "Paste a repository URL to give context" for mandatory types, keep "or skip for new projects" only for `:project`
- [x] `lib/destila_web/live/new_prompt_live.ex:28-31` (`set_repo` handler): When `@workflow_type != :project` and URL is empty, add a flash error "Repository URL is required" and stay on step 2 instead of advancing
- [x] `lib/destila_web/live/new_prompt_live.ex:33-35` (`skip_repo` handler): Guard against non-project types — only allow skip when `@workflow_type == :project`
- [x] `lib/destila_web/live/new_prompt_live.ex:70-147` (`create_prompt_with_idea/3`): For `:chore_task`, only add the first system message and the user's idea message (skip adding the second system message, since the AI will generate it). Set `steps_completed: 1`

#### Success Criteria
- [ ] Wizard shows 3 type cards on step 1
- [ ] Repo URL is mandatory for Feature Request and Chore/Task (can't skip or submit empty)
- [ ] Repo URL remains optional for Project
- [ ] Chore/Task prompt is created and navigates to detail view

### Phase 3: AI-Driven Phase System in PromptDetailLive

The core implementation — branching logic, async AI communication, and phase transitions.

#### Tasks

##### Data model additions
- [x] `lib/destila/store.ex:34-48`: Add `phase_status: nil` to prompt defaults
- [x] Message defaults (`lib/destila/store.ex:85-99`): Add `message_type: nil` to message defaults

##### PromptDetailLive branching
- [x] `lib/destila_web/live/prompt_detail_live.ex`: Add `ai_workflow?/1` helper that returns `true` for `:chore_task`
- [x] Rename `handle_user_response/3` → `handle_static_response/3`
- [x] Add `handle_ai_message/2` for AI-driven workflows
- [x] Update `handle_event("send_text", ...)` to branch: if `ai_workflow?(prompt)`, call `handle_ai_message/2`; otherwise call `handle_static_response/3`
- [x] Only show text input for AI-driven workflows (ignore single_select, multi_select, file_upload events)

##### Async AI communication
- [x] `handle_ai_message/2`: Adds user message to Store, sets `phase_status: :generating` on prompt, spawns a Task under `Destila.TaskSupervisor` that calls `AI.Session.query/2` with the phase-specific system prompt prepended
- [x] On Task completion: parse response for `<<READY_TO_ADVANCE>>` or `<<SKIP_PHASE>>` markers, add AI message to Store, update prompt `phase_status`
- [x] `handle_info({:ai_response, prompt_id, response}, socket)`: Refresh messages and prompt from Store, update assigns
- [x] `handle_info({:ai_error, prompt_id, error}, socket)`: Show flash error, reset `phase_status` to `:conversing`

##### Phase transitions
- [x] `handle_event("confirm_advance", ...)`: Increment `steps_completed`, insert `:phase_divider` message, reset `phase_status` to `:conversing`. If advancing to Phase 3, trigger Gherkin review AI prompt. If advancing past Phase 4, should not happen (Phase 4 completes via "Mark as Done")
- [x] `handle_event("decline_advance", ...)`: Reset `phase_status` to `:conversing`
- [x] Handle `<<SKIP_PHASE>>` signal (Phase 3 only): Auto-advance without user confirmation, insert divider message noting "No Gherkin changes needed"

##### Phase-specific AI system prompts
- [x] Create `lib/destila/workflows/chore_task_phases.ex` module with `system_prompt(phase_number, prompt)` that returns the appropriate system prompt for each phase

##### Session resumption
- [x] On `mount/3` for AI workflows: Check if `prompt.ai_session` PID is alive. If not, start a new session, build context summary from existing messages, send summary as first query, update prompt's `ai_session`
- [x] `build_context_summary/1`: Groups messages by phase, formats as "Phase N summary: [user messages summarized]"

##### Mark as Done (Phase 4)
- [x] `handle_event("mark_done", ...)`: Set `steps_completed: 4`, `column: :done`, `phase_status: nil`
- [x] Template: Show "Mark as Done" button in header when `ai_workflow? && steps_completed >= 4 && column != :done`

#### Success Criteria
- [ ] User can have a multi-turn conversation with the AI in Phase 1
- [ ] AI suggests advancing, confirmation buttons appear
- [ ] User can confirm or decline phase advance
- [ ] Phase dividers appear between phases
- [ ] Phase 3 reads repo and handles Gherkin review (or auto-skips)
- [ ] Phase 4 generates implementation prompt
- [ ] "Mark as Done" completes the workflow
- [ ] Progress bar updates correctly through phases

### Phase 4: Chat UI Enhancements

Typing indicator, phase dividers, input disabling, and phase advance confirmation UI.

#### Tasks

##### Typing indicator
- [x] `lib/destila_web/components/chat_components.ex`: Add `chat_typing_indicator/1` component — shows an AI avatar bubble with 3 animated dots

##### Phase advance confirmation
- [x] `lib/destila_web/components/chat_components.ex`: Update `chat_message/1` to detect `message_type: :phase_advance` and render two buttons below the message: "Continue to Phase N →" (`phx-click="confirm_advance"`) and "I have more to add" (`phx-click="decline_advance"`)

##### Phase dividers
- [x] `lib/destila_web/components/chat_components.ex`: Update `chat_message/1` to detect `message_type: :phase_divider` and render a horizontal divider with phase name (e.g., "Phase 2 — Technical Concerns")

##### Generated prompt styling
- [x] `lib/destila_web/components/chat_components.ex`: Update `chat_message/1` to detect `message_type: :generated_prompt` and render with a distinct visual treatment (border, header "Implementation Prompt", copy button)

##### Input disabling
- [x] `lib/destila_web/live/prompt_detail_live.ex` template: Pass `@prompt[:phase_status]` to `chat_input`. When `:generating`, disable the input field and show "AI is thinking..." placeholder
- [x] `lib/destila_web/components/chat_components.ex`: Add `disabled` attr to `text_input/1`, apply `disabled` class and swap placeholder

##### Progress display
- [x] `lib/destila_web/live/prompt_detail_live.ex` template: For AI workflows, show "Phase N/4 — Phase Name" instead of "N/4" in the header progress area
- [x] Create `phase_name/1` helper: maps phase number to name string

#### Success Criteria
- [ ] Typing indicator animates while AI processes
- [ ] Input is disabled during AI processing
- [ ] Phase advance buttons appear on advance-suggestion messages
- [ ] Phase dividers visually separate conversation phases
- [ ] Generated prompt has distinct styling
- [ ] Progress shows phase names for chore_task

### Phase 5: Error Handling & Polish

Handle edge cases, session failures, and ensure robustness.

#### Tasks

- [x] Handle AI session death mid-conversation: Detect in `spawn_ai_query/2`, auto-restart session with context summary, notify user
- [x] Handle AI query timeout: Error handling in spawn_ai_query, shows error message, resets `phase_status`
- [x] Handle empty AI responses: Show a "Something went wrong, please try again" message
- [x] Prevent double-send: Track `phase_status: :generating` in assigns; ignore `send_text` events while generating
- [x] Add seed data for chore_task prompts (in seeds.ex, Phase 1)
- [x] Update `current_step_info/2` for AI workflows: `ai_step_info/1` returns appropriate state based on phase_status

#### Success Criteria
- [ ] App recovers gracefully from AI session crashes
- [ ] No double messages on rapid clicking
- [ ] Seed data shows chore_task conversations on boards

## Files Changed Summary

### New Files
- `lib/destila/workflows/chore_task_phases.ex` — Phase system prompts for chore_task

### Modified Files
- `lib/destila/workflows.ex` — Add `:chore_task` clauses
- `lib/destila/ai.ex` — Add `:chore_task` label
- `lib/destila/store.ex` — Add `phase_status` and `message_type` defaults
- `lib/destila/seeds.ex` — Add chore_task seed data
- `lib/destila_web/live/new_prompt_live.ex` — Third type card, mandatory repo, chore_task creation
- `lib/destila_web/live/prompt_detail_live.ex` — Branch static/AI, async AI handling, phase transitions
- `lib/destila_web/components/chat_components.ex` — Typing indicator, phase dividers, advance buttons, prompt styling
- `lib/destila_web/components/board_components.ex` — `:chore_task` badge

## Dependencies & Risks

### Dependencies
- `ClaudeCode` hex package — already included, used for AI sessions
- `Req` — may be needed if ClaudeCode can't directly clone/browse repos (for GitHub API fallback in Phase 3)

### Risks

1. **AI response quality**: The phase system prompts need tuning. If the AI doesn't reliably produce `<<READY_TO_ADVANCE>>` markers, phase transitions break. **Mitigation:** Add a manual "Advance Phase" button as a fallback, visible after 3+ messages in a phase.

2. **Session timeout in long conversations**: 5-minute inactivity timeout may trigger during normal use if the user takes time to think. **Mitigation:** Context summary resumption. Consider increasing timeout to 15 minutes for chore_task workflows.

3. **Repo access in Phase 3**: ClaudeCode may not have permissions to access private repos. **Mitigation:** The AI should gracefully handle access failures and ask the user to paste relevant `.feature` file content.

4. **Memory growth**: Long AI conversations create many messages stored in a list assign. **Mitigation:** Acceptable for prototype. If needed later, migrate to LiveView streams.

## Success Metrics

- Users can create chore_task prompts through the wizard
- AI-driven conversation works end-to-end through all 4 phases
- Phase transitions feel natural (AI suggests, user confirms)
- Existing Feature Request and Project workflows are completely unaffected
- Progress indicator accurately reflects phase status

## References & Research

### Internal References
- Brainstorm: `docs/brainstorms/2026-03-19-chore-task-workflow-brainstorm.md`
- Workflow definitions: `lib/destila/workflows.ex`
- AI session: `lib/destila/ai/session.ex`
- Store (prompts/messages): `lib/destila/store.ex`
- Wizard: `lib/destila_web/live/new_prompt_live.ex`
- Chat detail: `lib/destila_web/live/prompt_detail_live.ex`
- Chat components: `lib/destila_web/components/chat_components.ex`
- Board components: `lib/destila_web/components/board_components.ex`
