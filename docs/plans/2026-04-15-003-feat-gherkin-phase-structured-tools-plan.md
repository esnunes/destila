---
title: "feat: Use structured tools in Gherkin Review phase"
type: feat
status: active
date: 2026-04-15
---

# feat: Use structured tools in Gherkin Review phase

## Overview

The Gherkin Review phase in the brainstorm idea workflow currently instructs the AI to "discuss with the user until they agree" via plain text. This means the AI proposes changes and asks open-ended questions, which is inconsistent with how other decision points in the app work. The prompt should instruct the AI to use `mcp__destila__ask_user_question` for structured choices and `mcp__destila__session` for phase transitions, giving users clickable options instead of free-form discussion.

## Problem Frame

When the AI finishes reviewing or proposing Gherkin scenarios, it asks in plain text whether the user agrees. This creates an unstructured interaction where the user must type a response. The app already has purpose-built tools for structured questions (`ask_user_question` with clickable options) and phase transitions (`session` with `suggest_phase_complete`). The prompt should guide the AI to use these tools at the appropriate decision points.

## Requirements Trace

- R1. After proposing Gherkin changes, the AI must use `mcp__destila__ask_user_question` to present approval/modification options instead of asking in plain text
- R2. When no feature files exist, the AI must use `mcp__destila__ask_user_question` to ask whether to create new scenarios
- R3. The AI must never call `ask_user_question` and a phase transition action in the same response (existing constraint from `tools.ex`)
- R4. The flow must still support the "Other" free-text option that `ask_user_question` provides automatically

## Scope Boundaries

- Only the `gherkin_review_prompt/1` function's prompt text changes — no code logic changes
- The tool definitions in `tools.ex` remain unchanged
- The response processor and session state machine remain unchanged
- The feature file scenarios for Phase 2 should be updated to reflect structured interaction

## Context & Research

### Relevant Code and Patterns

- `lib/destila/ai/tools.ex:10-56` — `ask_user_question` tool definition and usage guidelines: questions array with title (max 12 chars), question text, multi_select boolean, 2-4 options with label and description. "Other" free-text always available automatically
- `lib/destila/ai/tools.ex:54-55` — constraint: never call `ask_user_question` with phase transition in same response
- `lib/destila/ai/tools.ex:94-118` — `session` tool with `suggest_phase_complete` and `phase_complete` actions
- `lib/destila/workflows/brainstorm_idea_workflow.ex:81-127` — current `gherkin_review_prompt/1`
- `lib/destila/ai/claude_session.ex:19` — `ask_user_question` is already in the default allowed tools

## Key Technical Decisions

- **Rewrite prompt instructions only**: The tools already exist and work correctly. The gap is that the prompt doesn't instruct the AI to use them. Changing the prompt text is sufficient.
- **Two structured question points**: (1) After proposing changes — approve vs. request modifications, and (2) when no feature files exist — create scenarios vs. skip. Both map cleanly to `ask_user_question` with 2 options each.
- **Sequential tool use**: The prompt must make clear that `ask_user_question` comes first, the AI waits for the response, and only then calls `suggest_phase_complete` or `phase_complete` in a subsequent turn. This follows the existing constraint in `tools.ex`.

## Implementation Units

- [ ] **Unit 1: Rewrite gherkin_review_prompt/1 prompt text**

**Goal:** Update the system prompt to instruct the AI to use structured tools at decision points instead of plain text discussion.

**Requirements:** R1, R2, R3, R4

**Dependencies:** None

**Files:**
- Modify: `lib/destila/workflows/brainstorm_idea_workflow.ex`

**Approach:**
Rewrite the prompt text in `gherkin_review_prompt/1` (lines 101-126) to:

1. Keep the initial instructions about browsing the repo, finding feature files, and proposing changes in message text (this is the review/proposal part — plain text is correct here)
2. Replace "Discuss with the user until they agree" with instructions to call `mcp__destila__ask_user_question` with a structured question presenting approval options
3. For the "no feature files" branch, replace "Ask the user if they want to define new Gherkin scenarios" with instructions to call `mcp__destila__ask_user_question`
4. Add explicit instructions that after the user responds:
   - If the user approves → call `suggest_phase_complete`
   - If the user requests modifications → incorporate feedback, re-propose, and ask again
   - If the user chooses to skip → call `phase_complete`
5. Emphasize the constraint: never call `ask_user_question` and a phase transition in the same response

The structured questions should follow the tool schema constraints:
- Title: max 12 chars (e.g., "Gherkin")
- 2-3 options with label and description
- `multi_select: false` (single choice)
- Do not include an "Other" option (it's automatic)

**Patterns to follow:**
- The `@ask_user_question_details` prompt in `tools.ex:39-56` for tool usage guidelines
- The existing `task_description_prompt/1` for how to reference `mcp__destila__session` in prompt text

**Test scenarios:**
- Test expectation: none — this is a prompt text change with no behavioral code logic. The AI's behavior is driven by the prompt content, which is tested through integration with the actual LLM.

**Verification:**
- The `gherkin_review_prompt/1` function returns a string that references `mcp__destila__ask_user_question` at both decision points
- The prompt text maintains the constraint about not combining `ask_user_question` with phase transitions in the same response
- `mix compile` succeeds without warnings

- [ ] **Unit 2: Update Gherkin feature scenarios**

**Goal:** Update the feature file to reflect that the Gherkin Review phase now uses structured question tools instead of plain text discussion.

**Requirements:** R1, R2

**Dependencies:** Unit 1

**Files:**
- Modify: `features/brainstorm_idea_workflow.feature`

**Approach:**
Update the "Phase 2 - Gherkin Review" scenario (lines 63-67) to mention that the AI presents structured options for approval. Update the "Skip Gherkin Review" scenario (lines 69-73) if needed to clarify the auto-skip path. Consider whether new scenarios are needed for the structured question flow (e.g., user selects "Needs changes" and the AI re-proposes).

**Patterns to follow:**
- Existing scenarios for single-select and multi-select options (lines 110-124) which already describe the structured question UI
- The scenario style used throughout the file

**Test scenarios:**
- Test expectation: none — Gherkin feature files are specifications, not executable test code

**Verification:**
- Feature file scenarios accurately describe the new structured interaction flow
- No orphaned `@tag` references in test files pointing to removed/renamed scenarios

## System-Wide Impact

- **Interaction graph:** No new callbacks or middleware. The `ask_user_question` tool is already processed by `response_processor.ex:214` and the UI already renders structured questions. The prompt change simply makes the AI more likely to use this existing path.
- **Error propagation:** No change — the tool execute functions return static success strings.
- **State lifecycle risks:** None — the session state machine already handles the `ask_user_question` → `awaiting_input` → user responds → AI responds flow.
- **Unchanged invariants:** The `suggest_phase_complete` and `phase_complete` flows remain identical. The tool definitions, response processor, and session process are not modified.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| AI may not reliably follow the structured tool instructions | The prompt is explicit about when and how to use the tool, and the tool descriptions are already injected into the system prompt. This is consistent with how the AI uses these tools in other phases |
| "Other" free-text option may confuse the flow if user types unexpected input | The AI already handles free-text responses — the prompt should instruct it to interpret free-text as modification requests and re-propose |
