---
title: "fix: Scroll chat to bottom only when user was already at bottom"
type: fix
status: active
date: 2026-04-20
---

# fix: Scroll chat to bottom only when user was already at bottom

## Overview

The chat feed in `WorkflowRunnerLive` currently forces the scroll position to the bottom on every LiveView update. When the user scrolls up to re-read an earlier message and a new message arrives (or streaming chunks update), the hook yanks them back to the bottom, making it impossible to read scrolled-up content.

Change the `ScrollBottom` hook so it only auto-scrolls when the user was already at (or near) the bottom at the moment the DOM patch arrived. If the user has intentionally scrolled up, preserve their scroll position.

## Problem Frame

- Hook: `assets/js/app.js` `ScrollBottomHook` currently runs `this.el.scrollTop = this.el.scrollHeight` in both `mounted()` and `updated()`.
- Container: `<div id="chat-messages" phx-hook="ScrollBottom">` in `lib/destila_web/components/chat_components.ex:55`.
- Symptoms occur any time the chat re-renders while a user is reading earlier content — new `chat_message`, streaming tokens in `chat_processing_stream`, intermediate bubbles, or phase transitions.
- Expected behavior: behave like standard chat UIs (iMessage, Slack, ChatGPT). Auto-scroll when "stuck to bottom". Freeze when the user has scrolled up.

## Requirements Trace

- R1. When the user is at the bottom of `#chat-messages` and new content is rendered, the view scrolls to the new bottom.
- R2. When the user has scrolled up and new content is rendered, the scroll position does not change.
- R3. Initial mount of the chat still scrolls to the bottom (existing behavior preserved).
- R4. Streaming updates (rapid, repeated `updated()` calls with growing content) follow the same rule — do not hijack scroll if the user scrolled up partway through a streaming response.

## Scope Boundaries

- Only the `ScrollBottom` hook behavior is changed. No LiveView server-side logic or template changes.
- No new "Jump to bottom" button, unread badge, or similar UX affordance — not requested.
- No change to any other hook (`PhaseToggle`, `MarkdownCard`, etc.) or to other pages that don't use `ScrollBottom`.

## Context & Research

### Relevant Code and Patterns

- `assets/js/app.js:31-34` — current `ScrollBottomHook` definition (2 lines each for `mounted` and `updated`).
- `lib/destila_web/components/chat_components.ex:55` — the only consumer: `<div … id="chat-messages" phx-hook="ScrollBottom">`.
- `assets/js/app.js:36-42` `FocusFirstErrorHook` — shows the codebase's preferred shape for a tiny inline hook (local constant, no module file). Follow the same placement for this fix rather than extracting a new `assets/js/hooks/` file.
- LiveView hook lifecycle: `beforeUpdate()` runs with the pre-patch DOM still in place, `updated()` runs with the post-patch DOM — the canonical place to snapshot scroll intent and reapply it after patch.

### Institutional Learnings

- No prior `docs/solutions/` entry addresses sticky-scroll behavior; this fix establishes the pattern for the codebase.

## Key Technical Decisions

- **Snapshot "was at bottom?" in `beforeUpdate()`, decide in `updated()`**: this is the standard LiveView pattern and avoids racing with the patch. Reading scroll state in `updated()` alone would see the already-grown `scrollHeight` and mis-classify a mid-scroll user as "at bottom".
- **Threshold of ~24px** for "at bottom": sub-pixel rounding and the bottom padding of the container (`py-6`) mean `scrollHeight - scrollTop - clientHeight` is rarely exactly 0 even when visually pinned. A small tolerance avoids false negatives. Not user-configurable.
- **Inline hook, same file**: keep the hook inline in `assets/js/app.js` alongside the other small hooks (`FocusFirstError`, `AutoDismiss`). Extracting to `assets/js/hooks/` is reserved for hooks with real internal structure (see `terminal_panel.js`, `drafts_board.js`).
- **No server-side change**: the server has no knowledge of scroll position and doesn't need any. The fix is purely client-side.

## Open Questions

### Resolved During Planning

- **Should we scroll when the user sends a new message while scrolled up?** Out of scope — the current behavior sends via `phx-submit="send_text"` which triggers the same `updated()` path. If the user has explicitly submitted, they are usually at the bottom (the input sits below the stream), and if not, treating their own submit like any other update is acceptable and matches typical chat UIs. Revisit only if user feedback complains.
- **Threshold value**: 24px chosen as a pragmatic default (covers typical `py-6` bottom padding + sub-pixel rounding). If it feels wrong during manual verification, adjust in the same commit.

### Deferred to Implementation

- None.

## Implementation Units

- [ ] **Unit 1: Make `ScrollBottom` hook sticky-aware**

**Goal:** Replace the unconditional `updated()` scroll with a two-phase snapshot-and-reapply that preserves user scroll when they've scrolled up.

**Requirements:** R1, R2, R3, R4

**Dependencies:** None.

**Files:**
- Modify: `assets/js/app.js` (the `ScrollBottomHook` const, lines 31-34)

**Approach:**
- In `mounted()`, keep the existing behavior: scroll to bottom and initialize the "was at bottom" flag to `true`.
- Add `beforeUpdate()` that records, on the instance, whether the element was at the bottom *before* the DOM patch, using a small tolerance (`scrollHeight - scrollTop - clientHeight <= threshold`).
- In `updated()`, scroll to the bottom only when the recorded flag is true; otherwise do nothing.
- Use a module-local `const AT_BOTTOM_THRESHOLD_PX = 24` for the tolerance.
- Keep the hook inline in `assets/js/app.js` between the existing hooks — do not extract a new file.

**Patterns to follow:**
- `FocusFirstErrorHook` (`assets/js/app.js:36-42`) — short inline hook shape.
- The `beforeUpdate()` / `updated()` snapshot pattern described in the Phoenix LiveView JS Interop guide (standard LiveView hook lifecycle).

**Test scenarios:**
Test expectation: none — this is a pure client-side DOM/scroll behavior change in a small inline hook. The codebase has no JS test harness for inline hooks in `assets/js/app.js`, and the existing LiveView test suite cannot assert real browser scroll position against a rendered stylesheet. Verify manually per the Verification checklist. If regressions recur, the right follow-up is a feature-level browser test via `compound-engineering:test-browser`, not a JSDOM unit test of the hook.

**Verification:**
- Start the server with `elixir --sname destila -S mix phx.server` and open a workflow session that produces chat messages.
- Scroll to the bottom of `#chat-messages`, trigger a new message (e.g., send a response or wait for a streaming reply), and confirm the view auto-scrolls to include the new content.
- Scroll up into earlier messages, trigger a new message or let a streaming response continue, and confirm the scroll position does **not** change.
- Scroll up, then manually scroll back to the bottom, then trigger another update — confirm auto-scroll resumes.
- Reload the page mid-conversation — confirm the initial mount still lands at the bottom.
- Run `mix precommit` to confirm asset compilation and formatting pass.

## System-Wide Impact

- **Interaction graph:** Only `#chat-messages` in `chat_phase/1` uses this hook. No other consumers to update.
- **Error propagation:** N/A — the hook performs no network or server work.
- **State lifecycle risks:** The `_wasAtBottom` flag lives on the hook instance; it is recreated on re-mount, so navigation between sessions resets correctly.
- **Unchanged invariants:** The hook's `mounted()` contract (scroll to bottom on initial render) and the LiveView container's DOM id/selector are unchanged. No server-rendered markup changes.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Threshold too small → rounding keeps user "not at bottom" after they pinned scroll. | Use 24px tolerance; verify manually; easy to tune in the same file. |
| Threshold too large → user scrolled ~20px up still gets auto-scrolled. | 24px is small relative to a single chat message (~60-100px tall); acceptable tradeoff. |
| User resizes window mid-stream and scrollHeight/clientHeight shift. | `beforeUpdate()` reads live values on each patch, so resize between patches self-corrects; resize without a patch leaves the user's scroll untouched, which is the desired behavior. |
| Browsers that restore scroll on navigation conflict with `mounted()` scroll-to-bottom. | Existing behavior — unchanged by this fix. |

## Sources & References

- Current hook: `assets/js/app.js:31-34`
- Hook consumer: `lib/destila_web/components/chat_components.ex:55`
- Peer inline hook example: `assets/js/app.js:36-42` (`FocusFirstErrorHook`)
