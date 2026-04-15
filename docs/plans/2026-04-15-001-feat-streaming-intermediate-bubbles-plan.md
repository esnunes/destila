---
title: "feat: Show intermediate text bubbles during AI streaming"
type: feat
status: active
date: 2026-04-15
---

# Show Intermediate Text Bubbles During AI Streaming

## Overview

During LLM processing, replace the compact debug indicator with real chat bubbles that show intermediate text content as it arrives. Each qualifying streaming chunk (`AssistantMessage` with text blocks, `ResultMessage` with text) produces its own separate bubble with a distinct transient style (dashed border, muted colors). When processing completes, all intermediate bubbles are instantly removed and the single final merged message appears via the existing persistence path.

## Problem Frame

The current streaming UI shows either bouncing dots (no chunks yet) or a monospace debug line (`[assistant] truncated text...`). Users cannot read the AI's in-progress output, making long processing phases feel opaque. Showing the actual text as it streams gives users immediate feedback and lets them follow the AI's reasoning before the final message is persisted.

## Requirements Trace

- R1. `AssistantMessage` chunks with text content blocks produce intermediate bubbles
- R2. `ResultMessage` chunks with non-empty `.result` text produce intermediate bubbles
- R3. `ToolProgressMessage`, `ToolUseBlock`, `MCPToolUseBlock`, `PartialAssistantMessage`, and all other chunk types do NOT produce bubbles
- R4. Each qualifying chunk produces its own separate bubble (no accumulation/merging)
- R5. Intermediate bubbles use a distinct transient visual style (dashed border, muted/faded)
- R6. Intermediate bubbles are left-aligned like system messages
- R7. The typing indicator remains visible below the last intermediate bubble
- R8. When processing completes, all intermediate bubbles are instantly removed
- R9. The final merged message appears as a standard system bubble (existing behavior, no change)
- R10. Intermediate bubbles render markdown via `markdown_to_html/1`
- R11. Intermediate bubbles are ephemeral — never added to `@messages` or persisted to DB
- R12. Chat auto-scrolls as new intermediate bubbles appear
- R13. If no text chunks arrive (only tool use), the UI falls back to the typing indicator

## Scope Boundaries

- No changes to DB schema, `ResponseProcessor`, `Message` schema, or message persistence logic. Changes to the `workflow_session_updated` handler are limited to clearing ephemeral assigns (`@intermediate_bubbles`)
- No changes to the PubSub broadcast mechanism
- No throttling or debouncing of chunk processing (matches existing pattern; flagged as future optimization in prior plan)
- No accumulation/merging of intermediate bubbles — each chunk is independent
- The `chat_stream_debug` component is replaced by the new intermediate bubbles for text chunks but the typing indicator continues to serve its existing role

## Context & Research

### Relevant Code and Patterns

- `lib/destila_web/live/workflow_runner_live.ex` — `handle_info({:ai_stream_chunk, chunk})` at line 441 appends chunks to `@streaming_chunks`. `handle_info({:workflow_session_updated, ...})` at line 403 clears `@streaming_chunks` to `nil` when `phase_status` leaves `:processing`
- `lib/destila_web/components/chat_components.ex` — `chat_phase/1` at line 43 renders the chat UI. Lines 85-91 and 108-114 contain the streaming/typing decision tree. `chat_stream_debug/1` at line 696 renders the debug indicator. `format_chunk/1` at line 719 already extracts text from `AssistantMessage` via `Enum.filter(&match?(%ClaudeCode.Content.TextBlock{}, &1))`
- `markdown_to_html/1` at line 10 of `chat_components.ex` — Earmark-based markdown rendering with link sanitization
- System message bubble styling at line 373-419 — `bg-base-200 text-base-content`, `rounded-2xl px-4 py-3`, `prose prose-sm max-w-none`
- `ResultMessage` has `.result` field for text (seen in `claude_session.ex` line 280)
- `ScrollBottom` hook on `#chat-messages` container handles auto-scrolling

### Institutional Learnings

- The prior streaming plan (`docs/plans/2026-03-31-feat-stream-llm-output-to-ui-plan.md`) noted that partial markdown mid-stream (e.g., unclosed code blocks) may render oddly but Earmark handles it "gracefully in practice"
- No PubSub throttling was implemented; flagged as future optimization
- The inline-ai-conversation refactor confirmed `chat_phase/1` is a stateless function component receiving all data as assigns — the pattern to follow

## Key Technical Decisions

- **Separate `@intermediate_bubbles` assign instead of filtering `@streaming_chunks` in the template**: Extracting text and building bubble maps in the `handle_info` keeps template logic simple and avoids re-processing the full chunk list on every render. The assign is a plain list (not a stream) since it is ephemeral and cleared entirely on phase completion.
- **Replace `chat_stream_debug` usage rather than adding alongside it**: The intermediate bubbles serve the same purpose (showing streaming progress) with better UX. The `chat_stream_debug` component definition can remain for now but its call sites in `chat_phase/1` are replaced.
- **Each chunk = one bubble (no accumulation)**: Simpler state management and matches the requirement. The user sees each chunk as the AI produces it, and all are swept away when the final message arrives.
- **Typing indicator always shows during processing**: Rendered below intermediate bubbles as a "still working" signal. When no text chunks have arrived yet, it appears alone (existing behavior).

## Open Questions

### Resolved During Planning

- **Where to render intermediate bubbles relative to messages and typing indicator?** After the message `:for` loop, before/alongside the typing indicator. The typing indicator moves below the last intermediate bubble.
- **How to extract text from `ResultMessage`?** Use `msg.result` field — it contains the final text string. Only produce a bubble when `msg.result` is a non-empty binary.
- **Will `ScrollBottom` hook handle new intermediate bubbles?** Yes — the `ScrollBottom` hook's `updated()` callback fires whenever LiveView patches the `#chat-messages` element, which occurs when `@intermediate_bubbles` changes trigger a re-render.

### Deferred to Implementation

- **Exact Tailwind classes for the transient bubble style**: The plan specifies dashed border + muted colors; exact class choices are an implementation detail.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```
Chunk arrives via PubSub
  |
  v
handle_info({:ai_stream_chunk, chunk})
  |
  +-- Always: append chunk to @streaming_chunks (existing behavior)
  |
  +-- If AssistantMessage with text blocks:
  |     Extract text -> append bubble map to @intermediate_bubbles
  |
  +-- If ResultMessage with non-empty .result:
  |     Extract text -> append bubble map to @intermediate_bubbles
  |
  +-- Otherwise: no change to @intermediate_bubbles

Processing completes -> handle_info({:workflow_session_updated, ...})
  |
  +-- phase_status != :processing
  |     Set @streaming_chunks = nil (existing)
  |     Set @intermediate_bubbles = []
  |
  +-- assign_ai_state re-fetches messages from DB
        -> final merged message appears in @messages
```

Template rendering in `chat_phase/1`:

```
Messages (:for loop)
  |
  v
[if processing]
  |
  +-- Intermediate bubbles (:for loop over @intermediate_bubbles)
  |     Each: left-aligned, dashed border, muted, markdown-rendered
  |
  +-- Typing indicator (always shown during processing)
```

## Implementation Units

- [ ] **Unit 1: Add `@intermediate_bubbles` assign and chunk extraction logic in WorkflowRunnerLive**

**Goal:** Maintain a separate `@intermediate_bubbles` assign that accumulates bubble maps from qualifying streaming chunks.

**Requirements:** R1, R2, R3, R4, R8, R11, R13

**Dependencies:** None

**Files:**
- Modify: `lib/destila_web/live/workflow_runner_live.ex`

**Approach:**
- Initialize `@intermediate_bubbles` to `[]` in `mount` (alongside existing `streaming_chunks: nil`)
- In `handle_info({:ai_stream_chunk, chunk})`, after appending to `@streaming_chunks`, pattern-match on chunk type:
  - `AssistantMessage`: extract text from `message.content` by filtering `TextBlock` structs and joining `.text` fields. If non-empty, append a bubble map `%{id: System.unique_integer([:positive]), text: extracted_text}` to `@intermediate_bubbles`
  - `ResultMessage`: if `msg.result` is a non-empty binary, append a bubble map
  - All other types: no change to `@intermediate_bubbles`
- In `handle_info({:workflow_session_updated, ...})`, clear `@intermediate_bubbles` to `[]` in the same place `@streaming_chunks` is cleared (when `phase_status != :processing`)

**Patterns to follow:**
- Existing `@streaming_chunks` lifecycle pattern in the same file (init in mount, accumulate in chunk handler, clear in session update handler)
- Text extraction from `AssistantMessage` as done in `format_chunk/1` in `chat_components.ex` line 719-724

**Test scenarios:**
- Happy path: AssistantMessage with TextBlock content appends a bubble with extracted text to `@intermediate_bubbles`
- Happy path: ResultMessage with non-empty `.result` appends a bubble to `@intermediate_bubbles`
- Edge case: AssistantMessage with only ToolUseBlock content (no TextBlock) does not append a bubble
- Edge case: ResultMessage with nil or empty `.result` does not append a bubble
- Edge case: ToolProgressMessage, PartialAssistantMessage, and other chunk types do not append bubbles
- Happy path: When `phase_status` leaves `:processing`, `@intermediate_bubbles` is reset to `[]`
- Edge case: AssistantMessage with TextBlock containing only whitespace does not append a bubble
- Edge case: Multiple AssistantMessage chunks each produce their own separate bubble (no merging)

**Verification:**
- `@intermediate_bubbles` contains one bubble map per qualifying chunk
- Non-qualifying chunks leave `@intermediate_bubbles` unchanged
- Phase completion clears the list

- [ ] **Unit 2: Add intermediate bubble rendering component in ChatComponents**

**Goal:** Create a `chat_intermediate_bubble/1` component with transient visual style and markdown rendering.

**Requirements:** R5, R6, R10

**Dependencies:** Unit 1

**Files:**
- Modify: `lib/destila_web/components/chat_components.ex`

**Approach:**
- Add a new function component `chat_intermediate_bubble/1` that accepts a `:text` attr (string)
- Render as a left-aligned chat bubble with "D" avatar (matching system message layout), but with distinct transient styling: dashed border (`border border-dashed border-base-content/20`), slightly faded background/text (`bg-base-200/50 text-base-content/70`), to communicate "in-progress/temporary"
- Render the text content through `raw(markdown_to_html(text))` wrapped in `prose prose-sm max-w-none` — the `raw/1` call is required to emit unescaped HTML, matching the pattern at line 402 of `chat_components.ex`

**Patterns to follow:**
- `render_chat_message/1` at line 373 for the system message bubble structure (avatar + content layout)
- `markdown_to_html/1` usage at line 402 for markdown rendering in system messages

**Test scenarios:**
- Happy path: Component renders with the provided text content as markdown HTML
- Happy path: Component has the "D" avatar and left-aligned layout matching system messages
- Happy path: Component has distinct transient styling (dashed border classes present)

**Verification:**
- The intermediate bubble is visually distinct from standard system message bubbles
- Markdown content renders correctly (headings, code blocks, links, etc.)

- [ ] **Unit 3: Wire intermediate bubbles into `chat_phase/1` template**

**Goal:** Replace `chat_stream_debug` call sites with intermediate bubble rendering and ensure the typing indicator always shows during processing.

**Requirements:** R4, R7, R8, R12, R13

**Dependencies:** Unit 1, Unit 2

**Files:**
- Modify: `lib/destila_web/components/chat_components.ex` (template in `chat_phase/1`)
- Modify: `lib/destila_web/live/workflow_runner_live.ex` (pass `@intermediate_bubbles` to `chat_phase`)

**Approach:**
- Add `attr :intermediate_bubbles, :list, default: []` to `chat_phase/1`
- In `do_render_phase/1` in `workflow_runner_live.ex`, pass `intermediate_bubbles={@intermediate_bubbles}` to the `<.chat_phase>` call
- In both template branches of `chat_phase/1` (multi-phase `<details>` and single-phase `<div>`), replace the current streaming/typing block:
  - Old: `if processing -> if chunks -> stream_debug else -> typing_indicator`
  - New: `if processing -> for each bubble in @intermediate_bubbles -> render intermediate_bubble; always render typing_indicator`
- The typing indicator is now always shown when `phase_status == :processing`, appearing below any intermediate bubbles. When no intermediate bubbles exist (empty list), only the typing indicator shows — matching the current fallback behavior.
- Auto-scroll is handled by the existing `ScrollBottom` hook on `#chat-messages` since new DOM elements trigger it.

**Patterns to follow:**
- Existing `:for` loop pattern for messages in the template
- Existing conditional rendering pattern for `@phase_status == :processing`

**Test scenarios:**
- Happy path: During processing with intermediate bubbles, each bubble renders in the chat area followed by the typing indicator
- Happy path: During processing with no intermediate bubbles (empty list), only the typing indicator shows
- Edge case: When processing completes (intermediate_bubbles cleared), all intermediate bubbles disappear and the final message renders from @messages
- Integration: New intermediate bubbles added to the assign cause the chat to auto-scroll (ScrollBottom hook fires)

**Verification:**
- Intermediate bubbles appear in real time during AI processing
- Typing indicator is always visible below the last bubble during processing
- Transition to final message is instant with no stale intermediate bubbles remaining

- [ ] **Unit 4: Add Gherkin scenarios to feature file**

**Goal:** Document the streaming intermediate bubbles behavior in the BDD feature file.

**Requirements:** R1-R13

**Dependencies:** Units 1-3

**Files:**
- Modify: `features/brainstorm_idea_workflow.feature`

**Approach:**
- Add the specified scenarios before the "Aliveness Indicator" section (before line 150)
- Include the section header comment `# --- Streaming Message Bubbles ---`
- Add four scenarios: intermediate text bubbles appear, result text appears, tool messages don't create bubbles, intermediate bubbles replaced by final message

**Test expectation: none -- Gherkin feature file is documentation, not executable code**

**Verification:**
- Feature file contains the new scenarios in the correct location
- Scenario descriptions match the implemented behavior

- [ ] **Unit 5: Add LiveView tests for streaming intermediate bubbles**

**Goal:** Test the chunk-to-bubble extraction logic and template rendering behavior.

**Requirements:** R1-R4, R7, R8, R11, R13

**Dependencies:** Units 1-3

**Files:**
- Modify or create: `test/destila_web/live/workflow_runner_live_test.exs` (or relevant existing test file for WorkflowRunnerLive)

**Approach:**
- Test the `handle_info` behavior by sending chunk messages to the LiveView process and asserting on socket assigns
- Test template rendering by verifying intermediate bubble DOM elements appear/disappear based on assigns
- Tag all tests with `@tag feature: "brainstorm_idea_workflow"` and appropriate scenario tags

**Patterns to follow:**
- Existing LiveView test patterns in the test suite
- `Phoenix.LiveViewTest` functions (`render`, `has_element?`, etc.)

**Test scenarios:**
- Happy path: Sending an `AssistantMessage` chunk with text adds a bubble to `@intermediate_bubbles` and renders it in the DOM
- Happy path: Sending a `ResultMessage` chunk with non-empty result adds a bubble
- Edge case: Sending a `ToolProgressMessage` does not add a bubble
- Edge case: Sending an `AssistantMessage` with only tool use blocks does not add a bubble
- Happy path: Typing indicator is present during processing alongside intermediate bubbles
- Happy path: When phase completes, intermediate bubbles are cleared from the DOM and final message appears
- Edge case: No text chunks during processing — only typing indicator visible

**Verification:**
- All tests pass
- Tests cover the key behaviors documented in the Gherkin scenarios

## System-Wide Impact

- **Interaction graph:** Only `WorkflowRunnerLive` (chunk handler) and `ChatComponents` (rendering) are affected. No changes to `ClaudeSession`, `ResponseProcessor`, PubSub broadcasting, or message persistence.
- **Error propagation:** If `markdown_to_html/1` fails on partial markdown in a streaming chunk, Earmark's existing error handling applies (returns best-effort HTML). This is a known behavior from the original streaming plan.
- **State lifecycle risks:** `@intermediate_bubbles` is purely ephemeral. It is initialized to `[]` in mount, accumulated during processing, and cleared to `[]` on phase completion. On LiveView reconnect, it starts empty and the typing indicator shows until new chunks arrive — matching the existing `@streaming_chunks` reconnect behavior.
- **Unchanged invariants:** Message persistence, the `@messages` assign, `ResponseProcessor.process_message/2`, and the final message rendering path are completely untouched.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| High-frequency chunk updates cause excessive re-renders | Same risk exists today with `@streaming_chunks`; no throttling per existing pattern. Monitor and add throttling as future optimization if needed. |
| Partial markdown in intermediate bubbles renders oddly | Earmark handles partial markdown gracefully per prior plan findings. Intermediate bubbles are transient, so brief rendering artifacts are acceptable. |
| Many intermediate bubbles accumulate in a long processing run | Bubbles are lightweight maps in a plain list; the list is cleared entirely on completion. Memory impact is minimal compared to `@streaming_chunks` which stores full chunk structs. |

## Sources & References

- Related plan: `docs/plans/2026-03-31-feat-stream-llm-output-to-ui-plan.md` (original streaming architecture)
- Related plan: `docs/plans/2026-04-04-refactor-inline-ai-conversation-into-workflow-runner-plan.md` (current chat architecture)
- Related code: `lib/destila_web/live/workflow_runner_live.ex` (chunk handling, session update handling)
- Related code: `lib/destila_web/components/chat_components.ex` (chat rendering, streaming debug, typing indicator)
