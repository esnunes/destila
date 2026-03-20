---
title: "feat: Markdown view toggle for generated prompt"
type: feat
date: 2026-03-20
---

# feat: Markdown view toggle for generated prompt

## Overview

Add a Rendered/Markdown toggle and a copy-to-clipboard button to the "Implementation Prompt" card. The toggle switches between the existing rendered HTML view and a raw markdown view in a monospace code block. The copy button always copies the raw markdown regardless of which view is active.

Brainstorm: `docs/brainstorms/2026-03-20-markdown-view-toggle-brainstorm.md`
Feature file: `features/generated_prompt_viewing.feature`

## Problem Statement

Developers craft implementation prompts in Destila and then need to paste them into external tools (Claude Code, ChatGPT, IDE assistants). Copying from the rendered HTML view loses markdown structure (headings, lists, code blocks), producing mangled text. There is no way to access or copy the raw markdown.

## Proposed Solution

Modify the `:generated_prompt` clause of `chat_message/1` in `chat_components.ex` to:
1. Render **both** views (rendered HTML and raw markdown) in the template, hiding one via CSS
2. Add toggle buttons ("Rendered" / "Markdown") and a copy button to the card header
3. Use a colocated JS hook (`.PromptCard`) to manage toggle visibility and clipboard copy

### Architecture: Both Views Always Rendered

The critical insight is that `@messages` uses regular assigns (not streams), and `refresh_state/1` reassigns the full list on every PubSub event. This means the server re-renders message components frequently. To avoid toggle state being destroyed:

- **Render both views in HEEx** — the rendered HTML div and the raw markdown `<pre><code>` div are always in the DOM
- **CSS hides one** — the inactive view has `hidden` class
- **JS hook toggles visibility** — the `.PromptCard` hook swaps `hidden` classes and tracks state internally
- **`updated()` callback restores state** — when the server re-renders, the hook's `updated()` lifecycle callback re-applies the current toggle state

This avoids `phx-update="ignore"` entirely, so prompt refinement/replacement works naturally — the server sends new content for both views, and the hook preserves which view is active.

## Technical Considerations

### Curly Braces in Markdown

Raw markdown may contain `{` and `}` characters (e.g., JSON examples in prompts). The `<pre>` tag displaying raw markdown must use `phx-no-curly-interpolation` to prevent HEEx from interpreting these as expressions.

### Clipboard API Fallback

`navigator.clipboard.writeText()` requires a secure context (HTTPS) or localhost. For other environments, fall back to the legacy `document.execCommand('copy')` with a temporary textarea.

### Accessibility

- Toggle buttons use `role="tab"` within a `role="tablist"` container, with `aria-selected` indicating the active view
- Copy button has an `aria-label` that updates on success ("Copied!")
- Confirmation state uses `aria-live="polite"` for screen reader announcement

## Acceptance Criteria

- [x] The Implementation Prompt card shows "Rendered" and "Markdown" toggle buttons in the header
- [x] "Rendered" is active by default
- [x] Clicking "Markdown" shows raw markdown in a monospace `<pre><code>` block
- [x] Clicking "Rendered" returns to the rendered HTML view
- [x] A copy button is always visible in the header
- [x] Copy button copies raw markdown to clipboard regardless of active view
- [x] Copy button shows a checkmark confirmation icon for ~2 seconds
- [x] Toggle state survives server re-renders (new messages arriving, etc.)
- [x] Toggle resets to "Rendered" when the prompt content changes (refinement)

## Implementation

### 1. Update `chat_components.ex` — `:generated_prompt` clause

`lib/destila_web/components/chat_components.ex` (lines 72-91)

Replace the current card with:
- Header: "Implementation Prompt" label + tablist toggle (Rendered / Markdown) + copy button
- Body: two sibling divs — rendered HTML (visible by default) and raw markdown (hidden by default)
- Container: `id={"prompt-card-#{@message.id}"}`, `phx-hook=".PromptCard"`, `data-content={@message.content}`
- Raw markdown div: `<pre phx-no-curly-interpolation>` wrapping `<code>` with `@message.content` as text content
- Copy button: `hero-clipboard-document` icon, `id="copy-prompt-btn"`

```elixir
def chat_message(%{message: %{message_type: :generated_prompt}} = assigns) do
  ~H"""
  <div class="flex gap-3 mb-4">
    <div class="w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold flex-shrink-0 bg-primary text-primary-content">
      D
    </div>
    <div class="max-w-[80%]">
      <div
        id={"prompt-card-#{@message.id}"}
        class="rounded-2xl border-2 border-primary/20 bg-base-200 overflow-hidden"
        phx-hook=".PromptCard"
        data-content={@message.content}
      >
        <div class="px-4 py-2 bg-primary/10 border-b border-primary/20 flex items-center justify-between gap-2">
          <span class="text-xs font-medium text-primary uppercase tracking-wide">
            Implementation Prompt
          </span>
          <div class="flex items-center gap-1">
            <div role="tablist" class="flex rounded-lg bg-base-300/50 p-0.5">
              <button
                role="tab"
                aria-selected="true"
                data-view="rendered"
                class="prompt-tab px-2 py-0.5 text-xs font-medium rounded-md transition-colors bg-base-100 text-base-content shadow-sm"
              >
                Rendered
              </button>
              <button
                role="tab"
                aria-selected="false"
                data-view="markdown"
                class="prompt-tab px-2 py-0.5 text-xs font-medium rounded-md transition-colors text-base-content/50 hover:text-base-content"
              >
                Markdown
              </button>
            </div>
            <button
              class="prompt-copy-btn ml-1 p-1 rounded-md hover:bg-base-300/50 transition-colors"
              aria-label="Copy markdown to clipboard"
            >
              <.icon name="hero-clipboard-document-micro" class="size-4 text-base-content/50" />
            </button>
          </div>
        </div>
        <div data-rendered class="px-4 py-3 text-sm text-base-content prose prose-sm max-w-none">
          {raw(markdown_to_html(@message.content))}
        </div>
        <div data-markdown class="hidden px-4 py-3">
          <pre phx-no-curly-interpolation class="text-sm font-mono text-base-content whitespace-pre-wrap break-words bg-base-300/30 rounded-lg p-3 overflow-x-auto"><code>{@message.content}</code></pre>
        </div>
      </div>
    </div>
  </div>
  <script :type={Phoenix.LiveView.ColocatedHook} name=".PromptCard">
    export default {
      mounted() {
        this.activeView = "rendered"
        this.lastContent = this.el.dataset.content

        this.el.querySelectorAll(".prompt-tab").forEach(tab => {
          tab.addEventListener("click", () => this.switchView(tab.dataset.view))
        })

        this.el.querySelector(".prompt-copy-btn").addEventListener("click", () => this.copyMarkdown())
      },

      updated() {
        const newContent = this.el.dataset.content
        if (newContent !== this.lastContent) {
          this.lastContent = newContent
          this.activeView = "rendered"
        }
        this.applyView()
      },

      switchView(view) {
        this.activeView = view
        this.applyView()
      },

      applyView() {
        const rendered = this.el.querySelector("[data-rendered]")
        const markdown = this.el.querySelector("[data-markdown]")
        const tabs = this.el.querySelectorAll(".prompt-tab")

        if (this.activeView === "markdown") {
          rendered.classList.add("hidden")
          markdown.classList.remove("hidden")
        } else {
          rendered.classList.remove("hidden")
          markdown.classList.add("hidden")
        }

        tabs.forEach(tab => {
          const isActive = tab.dataset.view === this.activeView
          tab.setAttribute("aria-selected", isActive)
          if (isActive) {
            tab.classList.add("bg-base-100", "text-base-content", "shadow-sm")
            tab.classList.remove("text-base-content/50")
          } else {
            tab.classList.remove("bg-base-100", "text-base-content", "shadow-sm")
            tab.classList.add("text-base-content/50")
          }
        })
      },

      async copyMarkdown() {
        const content = this.el.dataset.content
        const btn = this.el.querySelector(".prompt-copy-btn")
        try {
          await navigator.clipboard.writeText(content)
          this.showCopyFeedback(btn, true)
        } catch {
          try {
            const ta = document.createElement("textarea")
            ta.value = content
            ta.style.position = "fixed"
            ta.style.opacity = "0"
            document.body.appendChild(ta)
            ta.select()
            document.execCommand("copy")
            document.body.removeChild(ta)
            this.showCopyFeedback(btn, true)
          } catch {
            this.showCopyFeedback(btn, false)
          }
        }
      },

      showCopyFeedback(btn, success) {
        const icon = btn.querySelector("span")
        const original = icon.className
        if (success) {
          icon.className = icon.className.replace("hero-clipboard-document-micro", "hero-check-micro")
          btn.setAttribute("aria-label", "Copied!")
        } else {
          icon.className = icon.className.replace("hero-clipboard-document-micro", "hero-x-mark-micro")
          btn.setAttribute("aria-label", "Copy failed")
        }
        clearTimeout(this._feedbackTimer)
        this._feedbackTimer = setTimeout(() => {
          icon.className = original
          btn.setAttribute("aria-label", "Copy markdown to clipboard")
        }, 2000)
      }
    }
  </script>
  """
end
```

### 2. Update feature file (if desired)

The SpecFlow analysis identified these potential additional scenarios:

```gherkin
Scenario: Toggle state persists during chat interaction
  Given I am viewing the markdown view
  When a new message arrives in the chat
  Then the markdown view should still be active

Scenario: Toggle resets when prompt is regenerated
  Given I am viewing the markdown view
  When the AI regenerates the implementation prompt
  Then the prompt card should display the rendered HTML view
  And the "Rendered" toggle should be active
```

### 3. Add tests

`test/destila_web/live/generated_prompt_viewing_live_test.exs`

Test what is verifiable in LiveViewTest (DOM structure, data attributes, element presence):

- [ ] Generated prompt card renders with toggle buttons ("Rendered" and "Markdown")
- [ ] Card has `phx-hook=".PromptCard"` attribute
- [ ] Card has `data-content` attribute with raw markdown
- [ ] Both `[data-rendered]` and `[data-markdown]` divs are present
- [ ] Copy button is present
- [ ] Rendered view contains HTML (prose wrapper)
- [ ] Markdown view contains raw text in `<pre><code>`

Link tests with `@tag feature: "generated_prompt_viewing", scenario: "..."`.

Note: Actual toggle interaction and clipboard copy are JS-driven and cannot be tested in LiveViewTest. These behaviors are tested implicitly via the hook's correctness and the DOM structure that enables it.

## References

- Brainstorm: `docs/brainstorms/2026-03-20-markdown-view-toggle-brainstorm.md`
- Feature file: `features/generated_prompt_viewing.feature`
- Current card component: `lib/destila_web/components/chat_components.ex:72-91`
- Message rendering: `lib/destila_web/live/prompt_detail_live.ex:765`
- Colocated hooks import: `assets/js/app.js:25`
- Existing hook pattern: `assets/js/hooks/sortable.js`
