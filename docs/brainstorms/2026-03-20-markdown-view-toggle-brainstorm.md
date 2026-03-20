# Markdown View Toggle for Generated Prompt

**Date:** 2026-03-20
**Status:** Decided

## What We're Building

A toggle on the "Implementation Prompt" card that lets users switch between the rendered HTML view and a raw markdown view displayed in a monospace code block. A copy-to-clipboard button is always visible in the card header, copying the raw markdown regardless of which view is active.

## Why This Approach

Developers who use Destila to craft implementation prompts need to copy the final prompt into other tools (Claude Code, ChatGPT, IDE assistants, etc.). The rendered HTML view loses the hierarchical structure expressed by markdown headings, lists, and code blocks. Copying from the rendered view strips formatting or produces inconsistent results. A raw markdown view with a dedicated copy button gives developers exactly what they need.

## Key Decisions

1. **Toggle between views** - Two-state toggle (Rendered / Markdown) on the Implementation Prompt card header, not a separate modal or expandable panel
2. **Applies to all prompt types** - The generated prompt card appears at the end of any prompt crafting workflow (not just Chore/Task). The toggle and copy features apply universally
3. **Scoped to generated prompt only** - Only the `message_type: :generated_prompt` card gets this feature, not all AI messages
4. **Monospace code block for markdown view** - Raw markdown displayed in a `<pre><code>` block with monospace font, familiar to developers
5. **Copy button always visible** - Copy-to-clipboard button present in the card header in both views, always copies the raw markdown content
6. **Colocated JS hook** - Use a Phoenix LiveView colocated hook (`.CopyMarkdown`) for clipboard interaction, keeping JS inline with the component

## Implementation Notes

- The raw markdown content is already available as `@message.content` in the `chat_message/1` component for `:generated_prompt` messages
- Toggle state can be managed client-side via the JS hook (no need for server round-trip)
- Clipboard API (`navigator.clipboard.writeText()`) for copy functionality
- Visual feedback on copy (e.g., icon changes from clipboard to checkmark briefly)

## Gherkin

- New feature file: `features/generated_prompt_viewing.feature`
- No changes needed to existing feature files (`create_prompt_wizard.feature`, `chore_task_workflow.feature`)

## Open Questions

None - all key decisions have been made through the brainstorm conversation.
