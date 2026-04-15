---
title: "feat: Allow editing previously answered questions in multi-question forms"
type: feat
status: completed
date: 2026-04-14
---

# feat: Allow editing previously answered questions in multi-question forms

## Overview

When the LLM asks multiple questions at once (via `ask_user_question` with multiple items), users answer each question sequentially and each answer locks in with a checkmark. Once locked, there is no way to change an answer before final submission. This plan adds the ability to click on a previously answered question to reopen it, change the selection, and then proceed to submit.

## Problem Frame

Users who misclick or change their mind on a multi-question form answer are forced to submit the wrong answer or refresh the page. Allowing answered cards to be reopened removes this friction without changing the overall sequential flow.

## Requirements Trace

- R1. Answered question cards become clickable — clicking one reopens it for editing
- R2. When reopened, the answer is removed from state and the question renders as interactive (same as first time)
- R3. Other answered questions retain their answers — only the clicked question reopens
- R4. After re-answering, the form advances to the next unanswered question, or shows "Submit All Answers" if all are answered
- R5. Answered cards have a visual affordance (cursor, hover effect) indicating they are clickable
- R6. Single-question flows (single-select instant submit, multi-select with confirm) are unchanged
- R7. "Submit All Answers" button only appears when every question has an answer
- R8. New Gherkin scenario added and linked to tests via `@tag` annotations

## Scope Boundaries

- Only the multi-question form flow (`input_type == :questions`) is affected
- Single-question single-select (instant submit) and single-question multi-select (checkbox + confirm) remain unchanged
- No changes to `ResponseProcessor`, `SessionProcess`, or the `submit_all_answers` handler logic beyond resetting the new assign

## Context & Research

### Relevant Code and Patterns

- `lib/destila_web/components/chat_components.ex` (line 982): `multi_question_input/1` renders three states per question — answered (locked card), active (interactive input), future (dimmed preview). Active question gated by `map_size(@answers) == idx`
- `lib/destila_web/live/workflow_runner_live.ex` (line 65): `question_answers` initialized as `%{}` on mount, reset on phase advance (line 127) and after `submit_all_answers` (line 266)
- `lib/destila_web/live/workflow_runner_live.ex` (line 214-246): `answer_question` and `confirm_multi_answer` handlers store answers via `Map.put` into `question_answers` map keyed by integer index
- `lib/destila_web/live/workflow_runner_live.ex` (line 1046): `chat_phase` receives `question_answers` as attr, threads it to `multi_question_input` at line 147
- `lib/destila_web/components/chat_components.ex` (line 35): `chat_phase` declares `question_answers` as required map attr
- `features/brainstorm_idea_workflow.feature` (line 120): Existing "Answer AI with a multi-question form" scenario
- `test/destila_web/live/brainstorm_idea_workflow_live_test.exs` (line 501): Existing test uses `create_session_with_questions()` helper and element selectors like `button[phx-click='answer_question'][phx-value-answer='Phoenix']`

### Key Architectural Constraint

`chat_phase/1` and `multi_question_input/1` are stateless function components — all state lives in `WorkflowRunnerLive`. The new `editing_question_index` assign must be owned by the LiveView and threaded through attrs. Events bubble up to `WorkflowRunnerLive` handlers.

The multi-question form is rendered outside of a LiveView stream (it's in the active input area at `chat_components.ex` line 140-149), so simple assign changes will trigger re-renders without needing `stream_insert`.

## Key Technical Decisions

- **Use `editing_question_index` assign rather than modifying the `map_size` gating logic**: The existing `map_size(@answers) == idx` approach fundamentally ties active question to sequential position. Removing an answer from the map to "reopen" it would shift which question appears active in confusing ways. An explicit `editing_question_index` assign cleanly separates "which question is being edited" from "which questions have answers." When `editing_question_index` is `nil`, the component falls back to showing the first unanswered question (preserving the original sequential behavior for initial answering).

- **Remove answer from map on reopen rather than keeping it**: When a user clicks an answered card, the answer at that index is deleted from `question_answers`. This means the interactive input renders in its default state (no pre-selected option), matching the original answering experience. This is simpler than trying to pre-populate the previous selection, and the user clicked to change it anyway.

- **Reset `editing_question_index` to `nil` on answer, not to the next unanswered index**: After answering the reopened question, setting `editing_question_index` back to `nil` lets the existing "first unanswered question" fallback logic handle advancement. This keeps the logic in one place.

## Open Questions

### Resolved During Planning

- **Should reopening clear subsequent answers?** No — only the clicked question's answer is removed. Other answers are retained per R3.
- **Should the answered card pre-select the previous answer when reopened?** No — the answer is removed from state and the question renders fresh. Simpler implementation and the user clicked to change it.
- **Where does the multi-question form render relative to streams?** It renders in the active input area (`chat_components.ex` line 140-149), outside the message stream. Assign changes alone trigger re-renders.

### Deferred to Implementation

- Exact hover transition timing and visual polish for the clickable answered cards — will be refined when seeing the actual UI.

## Implementation Units

- [ ] **Unit 1: Add `editing_question_index` assign and `reopen_question` event handler**

  **Goal:** Wire up the new state and event handler in `WorkflowRunnerLive` so reopening a question removes its answer and tracks which question is being edited.

  **Requirements:** R1, R2, R3

  **Dependencies:** None

  **Files:**
  - Modify: `lib/destila_web/live/workflow_runner_live.ex`

  **Approach:**
  - Add `editing_question_index: nil` to the initial assigns at mount (line 65) and at phase advance reset (line 127)
  - Add `handle_event("reopen_question", %{"index" => idx_str}, socket)` that parses the index to integer, removes that key from `question_answers` via `Map.delete`, and sets `editing_question_index` to the parsed index. Use `Integer.parse/1` and handle the `:error` case by returning socket unchanged
  - Add a catch-all `handle_event("reopen_question", _params, socket)` clause that returns `{:noreply, socket}`, mirroring the existing `answer_question` catch-all at line 226
  - In the existing `answer_question` handler (line 214), after storing the answer, reset `editing_question_index` to `nil`
  - In the existing `confirm_multi_answer` handler (line 228), after storing the answer, reset `editing_question_index` to `nil`
  - In the existing `submit_all_answers` handler (line 266), reset `editing_question_index` to `nil` alongside the `question_answers: %{}` reset
  - Pass `editing_question_index` to `chat_phase` in the template (line 1040-1051)

  **Patterns to follow:**
  - The existing `answer_question` handler pattern for parsing index strings and updating socket assigns
  - The existing assign threading pattern: LiveView -> `chat_phase` attr -> `multi_question_input` attr

  **Test scenarios:**
  - Happy path: Reopening a question removes its answer from the `question_answers` map and sets `editing_question_index` to that index
  - Happy path: Answering a question after reopening resets `editing_question_index` to `nil`
  - Edge case: Reopening with an invalid index string (non-integer) does not crash — returns socket unchanged

  **Verification:**
  - The `reopen_question` event is handled without error
  - After reopening, the question's answer is no longer in the assigns and `editing_question_index` reflects the reopened index
  - After re-answering, `editing_question_index` returns to `nil`

- [ ] **Unit 2: Update `multi_question_input` to support editing and clickable answered cards**

  **Goal:** Make the component accept `editing_question_index`, render answered cards as clickable, and use the new assign to determine which question is active.

  **Requirements:** R1, R2, R4, R5, R7

  **Dependencies:** Unit 1

  **Files:**
  - Modify: `lib/destila_web/components/chat_components.ex`

  **Approach:**
  - Add `attr :editing_question_index, :integer, default: nil` to `multi_question_input/1` (after line 980)
  - Add `editing_question_index` attr declaration to `chat_phase/1` (after line 35) and thread it to the `multi_question_input` call at line 145-148
  - Replace the active question condition: instead of `map_size(@answers) == idx`, the question is interactive if `@editing_question_index == idx`, or if `@editing_question_index == nil` and `idx` is the smallest index not in `@answers`
  - Compute `active_index` in the function body: if `editing_question_index` is not nil, use it; otherwise find the first index from 0..total-1 not in the answers map (or nil if all answered)
  - Change the answered card container (line 998) to a `<button>` element (or add `role="button"` and `tabindex="0"` to the div) with `phx-click="reopen_question"`, `phx-value-index={idx}`, and hover/focus styles using class list syntax: `class={["cursor-pointer hover:border-primary/30 hover:bg-base-200/50 transition-colors focus:outline-none focus:ring-2 focus:ring-primary/30", ...]}`
  - The `all_answered` condition for the "Submit All Answers" button stays the same (`answered == total`) — it naturally hides when any answer is removed
  - Ensure the dimmed/future state still applies to questions whose index is greater than the active index and that are not answered

  **Patterns to follow:**
  - The existing three-state rendering pattern (answered/active/future) in `multi_question_input/1`
  - The existing attr declaration and threading pattern through `chat_phase` -> `multi_question_input`
  - HEEx class list syntax with conditionals as shown in CLAUDE.md

  **Test scenarios:**
  - Happy path: Clicking an answered card fires `reopen_question` event with the correct index
  - Happy path: Reopened question renders as interactive (shows option buttons / checkboxes)
  - Happy path: Other answered questions remain displayed as answered cards
  - Happy path: After re-answering, the form advances to the next unanswered question or shows "Submit All Answers" if all answered
  - Happy path: Answered cards show cursor-pointer and hover effect indicating they are clickable
  - Edge case: Reopening the last answered question (when all were answered) hides the "Submit All Answers" button
  - Integration: Full flow — answer all questions, reopen one, change answer, submit — sends correct formatted response

  **Verification:**
  - Answered cards are visually clickable with cursor and hover effect
  - Clicking an answered card reopens it for editing
  - The "Submit All Answers" button correctly appears/disappears based on answer completeness
  - Single-question flows remain unaffected (they do not use `multi_question_input`)

- [ ] **Unit 3: Add Gherkin scenario and tests**

  **Goal:** Add the new Gherkin scenario and corresponding LiveView tests for the edit-question behavior.

  **Requirements:** R8, R1, R2, R3, R4, R5, R7

  **Dependencies:** Unit 1, Unit 2

  **Files:**
  - Modify: `features/brainstorm_idea_workflow.feature`
  - Modify: `test/destila_web/live/brainstorm_idea_workflow_live_test.exs`

  **Approach:**
  - Add the Gherkin scenario "Edit a previously answered question in multi-question form" to `features/brainstorm_idea_workflow.feature` after the existing "Answer AI with a multi-question form" scenario (line 124)
  - Add a new test in the existing `"AI multi-question form"` describe block with `@tag feature: @feature, scenario: "Edit a previously answered question in multi-question form"`
  - Use the existing `create_session_with_questions()` helper to set up the session
  - Test the full editing flow: answer first question, verify lock-in, click answered card to reopen, verify it renders as interactive again, answer with a different selection, verify new answer locks in, answer remaining questions, verify "Submit All Answers" appears, submit and verify correct formatted response

  **Patterns to follow:**
  - The existing multi-question test at line 501-531: `create_session_with_questions()`, element selectors with `phx-click` and `phx-value-*` attributes, `has_element?` assertions
  - `@tag feature: @feature, scenario: "..."` annotation pattern

  **Test scenarios:**
  - Happy path: Answer first question, click answered card, question reopens as interactive, select new option, answer locks in with new value, complete remaining questions, submit all — formatted response contains the new answer
  - Happy path: Answered card has clickable affordance (test for the `phx-click="reopen_question"` attribute on answered cards)
  - Happy path: Other answered questions retain their answers when one is reopened
  - Edge case: "Submit All Answers" button disappears when a question is reopened and reappears after re-answering

  **Verification:**
  - All new tests pass with `mix test test/destila_web/live/brainstorm_idea_workflow_live_test.exs`
  - Tests are linked to the Gherkin scenario via `@tag`
  - Existing multi-question test continues to pass (no regression)

## System-Wide Impact

- **Interaction graph:** Only `WorkflowRunnerLive` event handlers and `chat_components.ex` function components are affected. No callbacks, middleware, or observers are involved. Events flow: template `phx-click` -> `WorkflowRunnerLive.handle_event/3` -> assign update -> re-render.
- **Error propagation:** Invalid index strings in `reopen_question` are handled the same way as in the existing `answer_question` handler — `Integer.parse` returns `:error` and the socket is returned unchanged.
- **State lifecycle risks:** None. `question_answers` and `editing_question_index` are transient assigns that live only for the duration of one multi-question interaction. They are reset on phase advance and after submit.
- **API surface parity:** No other interfaces consume these assigns. The `submit_all_answers` handler already iterates questions by index and looks up answers, so it works correctly regardless of answer order.
- **Unchanged invariants:** Single-question flows (`input_type in [:single_select, :multi_select]`) go through `chat_input/1`, not `multi_question_input/1`. They are completely unaffected by this change.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Reopening a question while another is in "Other (type your own)" text input state could confuse users | Low risk — the reopen replaces the active question, and the text input for the original active question disappears naturally on re-render |
| Adding `phx-click` to answered cards could accidentally trigger on non-multi-question contexts | `multi_question_input/1` is only rendered when `input_type == :questions`, which only activates for 2+ questions. Single-question flows use different components entirely |

## Sources & References

- Related code: `lib/destila_web/components/chat_components.ex` (line 982, `multi_question_input/1`)
- Related code: `lib/destila_web/live/workflow_runner_live.ex` (lines 65, 214-266, 1040-1051)
- Related test: `test/destila_web/live/brainstorm_idea_workflow_live_test.exs` (line 501)
- Related feature: `features/brainstorm_idea_workflow.feature` (line 120)
