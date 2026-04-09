---
title: "feat: Inline metadata cards in chat messages"
type: feat
date: 2026-04-08
---

# feat: Inline metadata cards in chat messages

## Overview

When the AI exports metadata via the `mcp__destila__session` tool with `action: "export"`, the exported value currently only appears in the collapsible right sidebar. This feature adds inline chat rendering: each AI response that contains export tool calls gets styled metadata cards injected immediately after the message bubble. Markdown-type exports get a full card with rendered/raw toggle and copy button; all other types get a simpler card with the value and a copy button.

This also removes the phase-level `message_type: :generated_prompt` mechanism. The brainstorm workflow's "Prompt Generation" phase previously hard-coded this message type to trigger a special card renderer. That's replaced by the generic export-detection approach — any AI response with export tool calls gets inline cards, regardless of which phase it's in.

The existing `generated_prompt` component in `chat_components.ex` is renamed to `markdown_card` and generalized with a dynamic header. A new `plain_card` component handles non-markdown types.

## Current state

- **Phase definition** (`lib/destila/workflows/brainstorm_idea_workflow.ex:25-29`): Phase 4 "Prompt Generation" sets `message_type: :generated_prompt` on the Phase struct.
- **Phase struct** (`lib/destila/workflows/phase.ex:12`): Has a `:message_type` field. Only used by the brainstorm workflow.
- **Message type detection** (`lib/destila/ai/response_processor.ex:183-205`): `derive_message_type/3` checks `phase_def.message_type == :generated_prompt` as the first condition (line 187). If matched, returns `{nil, :generated_prompt}`.
- **Content override** (`lib/destila/ai/response_processor.ex:45-50`): For `:generated_prompt`, always uses stored `msg.content`; for other types, uses session tool override content or stored content.
- **Generated prompt renderer** (`lib/destila_web/components/chat_components.ex:331-467`): `render_chat_message/1` pattern-matches on `message_type: :generated_prompt` and renders a styled card with rendered/markdown toggle tabs, copy button, and `.PromptCard` JS hook.
- **Default message renderer** (`lib/destila_web/components/chat_components.ex:469-516`): Regular chat bubble for system and user messages.
- **Export extraction** (`lib/destila/ai/response_processor.ex:119-127`): `extract_export_actions/1` parses `raw_response` MCP tool uses for export actions. Returns `[%{key, value, type}]`. Currently only called from `conversation.ex` for persistence — NOT from `process_message/2`.
- **Processed message map** (`lib/destila/ai/response_processor.ex:68-79`): Map returned by `process_message/2` has fields: `id`, `role`, `phase`, `content`, `selected`, `inserted_at`, `message_type`, `input_type`, `options`, `questions`. No `exports` field.
- **Humanize key** (`lib/destila_web/live/workflow_runner_live.ex:770-772`): `humanize_key/1` does `String.replace("_", " ") |> String.capitalize()` — only capitalizes the first word. Used in sidebar.
- **Sidebar** (`lib/destila_web/live/workflow_runner_live.ex:542-635`): Renders exported metadata in collapsible `<details>` blocks. Unchanged by this feature.
- **Feature file** (`features/generated_prompt_viewing.feature`): 39-line file describing the prompt card behavior, scoped to "generated prompt" terminology.
- **Feature file** (`features/exported_metadata.feature`): 57-line file covering sidebar behavior. No inline chat scenarios.

## Key design decisions

### 1. Export detection happens in `process_message/2`, not in the template

Calling `extract_export_actions/1` inside `process_message/2` and adding an `:exports` field to the processed message map keeps the template simple. The template just iterates `@message.exports` — no raw_response parsing in HEEx.

### 2. `chat_message/1` renders both the message and its export cards

Rather than changing the `:for` loop in `chat_phase/1`, `chat_message/1` itself returns both the message bubble (via `render_chat_message`) and any export cards. This keeps the call site clean and ensures cards are always paired with their message.

### 3. Markdown vs non-markdown is determined by the export's type field

If `export.type` is `"markdown"`, render `markdown_card`. For all other types (`"text"`, `"text_file"`, `"video_file"`, or nil which defaults to `"text"`), render `plain_card`. This is a simple conditional in the template.

### 4. The `.PromptCard` hook is renamed to `.MarkdownCard`

The hook behavior (tab switching, copy, icon feedback) is identical. Only the name changes. A new `.PlainCard` hook handles copy-only behavior for non-markdown cards.

### 5. `humanize_key` is updated to title-case and defined in both modules

Both `chat_components.ex` (for inline cards) and `workflow_runner_live.ex` (for the sidebar) need `humanize_key`. It's a one-liner, so defining it as a private function in each module avoids unnecessary coupling. The implementation changes from `String.capitalize/1` (first word only) to splitting on `_` and capitalizing each word.

### 6. Removing `message_type: :generated_prompt` is safe because export actions are skipped by `extract_session_action`

`extract_session_action/1` (line 148) explicitly skips `action: "export"`. So when the only session tool call is an export (as in the prompt generation phase), `derive_message_type/3` returns `{nil, nil}` — the message renders as a normal bubble. The export card is then injected by the new code path. Existing persisted messages work correctly because the detection reads `raw_response` at render time.

### 7. The `:message_type` field is removed from the Phase struct

Only the brainstorm workflow sets `message_type: :generated_prompt`. No other workflow uses this field. After removing the detection logic, the field is dead code. Removing it from `Phase` keeps the struct clean.

## Changes

### Step 1: Add `:exports` to `process_message/2`

**File:** `lib/destila/ai/response_processor.ex`

In the system message handler (lines 38-80), after extracting `message_type` and `tool_input`, also extract export actions and include them in the returned map.

Add after line 41:

```elixir
exports = extract_export_actions(raw)
```

Add to the returned map at line 79 (before the closing `}`):

```elixir
exports: exports
```

Also add `exports: []` to the user message handler (line 34) and the system-without-raw fallback (line 93).

### Step 2: Remove `message_type: :generated_prompt` detection

**File:** `lib/destila/ai/response_processor.ex`

In `derive_message_type/3` (lines 183-205), remove the first `cond` clause (lines 187-188) AND the now-unused `phase_def` variable (line 184):

```elixir
# Before (lines 183-205):
defp derive_message_type(raw, phase, workflow_session) do
  phase_def = get_phase_def(workflow_session.workflow_type, phase)

  cond do
    phase_def && phase_def.message_type == :generated_prompt ->
      {nil, :generated_prompt}

    session = extract_session_action(raw) ->
      ...
  end
end

# After:
defp derive_message_type(raw, _phase, _workflow_session) do
  cond do
    session = extract_session_action(raw) ->
      case session.action do
        "suggest_phase_complete" ->
          {session.message || "Ready to move to the next phase.", :phase_advance}

        "phase_complete" ->
          {session.message || "Moving to the next phase.", :phase_advance}

        _ ->
          {nil, nil}
      end

    true ->
      {nil, nil}
  end
end
```

**Also delete `get_phase_def/2`** (lines 207-209) — it is now unreferenced dead code. This removal is **required**: `mix precommit` runs `compile --warnings-as-errors`, so any unused variable or function will fail the build.

Also remove the special content handling for `:generated_prompt` at lines 45-50:

```elixir
# Before:
content =
  if message_type == :generated_prompt do
    String.trim(msg.content)
  else
    override_content || String.trim(msg.content)
  end

# After:
content = override_content || String.trim(msg.content)
```

This is safe because for messages with only export tool calls (no `suggest_phase_complete` or `phase_complete`), `override_content` is nil and falls through to stored content — same behavior as the removed `:generated_prompt` branch.

### Step 3: Remove `message_type` from Phase struct and brainstorm workflow

**File:** `lib/destila/workflows/phase.ex`

Remove `:message_type` from the struct:

```elixir
# Before (line 9-16):
defstruct [
  :name,
  :system_prompt,
  :message_type,
  non_interactive: false,
  allowed_tools: [],
  session_strategy: :resume
]

# After:
defstruct [
  :name,
  :system_prompt,
  non_interactive: false,
  allowed_tools: [],
  session_strategy: :resume
]
```

**File:** `lib/destila/workflows/brainstorm_idea_workflow.ex`

Remove `message_type: :generated_prompt` from Phase 4:

```elixir
# Before (lines 25-29):
%Phase{
  name: "Prompt Generation",
  system_prompt: &prompt_generation_prompt/1,
  message_type: :generated_prompt
}

# After:
%Phase{name: "Prompt Generation", system_prompt: &prompt_generation_prompt/1}
```

### Step 4: Add `humanize_key` to ChatComponents

**File:** `lib/destila_web/components/chat_components.ex`

Add a private helper function (near the bottom, alongside other helpers):

```elixir
defp humanize_key(key) when is_binary(key) do
  key
  |> String.split("_")
  |> Enum.map_join(" ", &String.capitalize/1)
end
```

### Step 5: Create `markdown_card` function component

**File:** `lib/destila_web/components/chat_components.ex`

Add a new function component. This is the renamed/generalized version of the `render_chat_message(%{message: %{message_type: :generated_prompt}})` handler. Key differences from the old version:

- Accepts `id`, `key`, `content` attrs instead of pulling from `@message`
- Header shows `humanize_key(@key)` instead of hard-coded "Implementation Prompt"
- Hook renamed from `.PromptCard` to `.MarkdownCard`
- CSS class names for copy button updated for consistency

```elixir
attr :id, :string, required: true
attr :key, :string, required: true
attr :content, :string, required: true

defp markdown_card(assigns) do
  ~H"""
  <div class="flex gap-3 mb-4">
    <div class="w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold flex-shrink-0 bg-primary text-primary-content">
      D
    </div>
    <div class="max-w-[80%]">
      <div
        id={@id}
        class="rounded-2xl border-2 border-primary/20 bg-base-200 overflow-hidden"
        phx-hook=".MarkdownCard"
        data-content={@content}
      >
        <div class="px-4 py-2 bg-primary/10 border-b border-primary/20 flex items-center justify-between gap-2">
          <span class="text-xs font-medium text-primary uppercase tracking-wide">
            {humanize_key(@key)}
          </span>
          <div class="flex items-center gap-1">
            <div role="tablist" class="flex rounded-lg bg-base-300/50 p-0.5">
              <button
                role="tab"
                aria-selected="true"
                data-view="rendered"
                class="md-card-tab px-2 py-0.5 text-xs font-medium rounded-md transition-colors bg-base-100 text-base-content shadow-sm"
              >
                Rendered
              </button>
              <button
                role="tab"
                aria-selected="false"
                data-view="markdown"
                class="md-card-tab px-2 py-0.5 text-xs font-medium rounded-md transition-colors text-base-content/50 hover:text-base-content"
              >
                Markdown
              </button>
            </div>
            <button
              class="md-card-copy-btn ml-1 p-1 rounded-md hover:bg-base-300/50 transition-colors"
              aria-label="Copy markdown to clipboard"
            >
              <.icon name="hero-clipboard-document-micro" class="size-4 text-base-content/50" />
            </button>
          </div>
        </div>
        <div data-rendered class="px-4 py-3 text-sm text-base-content prose prose-sm max-w-none">
          {raw(markdown_to_html(@content))}
        </div>
        <div data-markdown class="hidden px-4 py-3">
          <pre class="text-sm font-mono text-base-content whitespace-pre-wrap break-words bg-base-300/30 rounded-lg p-3 overflow-x-auto"><code>{@content}</code></pre>
        </div>
      </div>
    </div>
  </div>
  """
end
```

The `.MarkdownCard` colocated hook is identical to the old `.PromptCard` but with renamed CSS selectors:

```html
<script :type={Phoenix.LiveView.ColocatedHook} name=".MarkdownCard">
  export default {
    mounted() {
      this.activeView = "rendered"
      this.lastContent = this.el.dataset.content

      this.el.querySelectorAll(".md-card-tab").forEach(tab => {
        tab.addEventListener("click", () => this.switchView(tab.dataset.view))
      })

      this.el.querySelector(".md-card-copy-btn").addEventListener("click", () => this.copyMarkdown())
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
      const tabs = this.el.querySelectorAll(".md-card-tab")

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
      const btn = this.el.querySelector(".md-card-copy-btn")
      try {
        await navigator.clipboard.writeText(content)
        this.showCopyFeedback(btn, true)
      } catch {
        this.showCopyFeedback(btn, false)
      }
    },

    showCopyFeedback(btn, success) {
      const icon = btn.querySelector("[class*='hero-']")
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
```

Place the `<script>` tag once in `chat_message/1`'s template (after the export card loop) so it's only defined once.

### Step 6: Create `plain_card` function component

**File:** `lib/destila_web/components/chat_components.ex`

A simpler card for non-markdown types. No tabs — just header, content, and copy button.

```elixir
attr :id, :string, required: true
attr :key, :string, required: true
attr :content, :string, required: true

defp plain_card(assigns) do
  ~H"""
  <div class="flex gap-3 mb-4">
    <div class="w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold flex-shrink-0 bg-primary text-primary-content">
      D
    </div>
    <div class="max-w-[80%]">
      <div
        id={@id}
        class="rounded-2xl border-2 border-primary/20 bg-base-200 overflow-hidden"
        phx-hook=".PlainCard"
        data-content={@content}
      >
        <div class="px-4 py-2 bg-primary/10 border-b border-primary/20 flex items-center justify-between gap-2">
          <span class="text-xs font-medium text-primary uppercase tracking-wide">
            {humanize_key(@key)}
          </span>
          <button
            class="plain-card-copy-btn p-1 rounded-md hover:bg-base-300/50 transition-colors"
            aria-label="Copy to clipboard"
          >
            <.icon name="hero-clipboard-document-micro" class="size-4 text-base-content/50" />
          </button>
        </div>
        <div class="px-4 py-3 text-sm text-base-content whitespace-pre-wrap break-words">
          {@content}
        </div>
      </div>
    </div>
  </div>
  """
end
```

The `.PlainCard` colocated hook — copy only:

```html
<script :type={Phoenix.LiveView.ColocatedHook} name=".PlainCard">
  export default {
    mounted() {
      this.el.querySelector(".plain-card-copy-btn")
        .addEventListener("click", () => this.copyContent())
    },

    async copyContent() {
      const content = this.el.dataset.content
      const btn = this.el.querySelector(".plain-card-copy-btn")
      try {
        await navigator.clipboard.writeText(content)
        this.showCopyFeedback(btn, true)
      } catch {
        this.showCopyFeedback(btn, false)
      }
    },

    showCopyFeedback(btn, success) {
      const icon = btn.querySelector("[class*='hero-']")
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
        btn.setAttribute("aria-label", "Copy to clipboard")
      }, 2000)
    }
  }
</script>
```

### Step 7: Update `chat_message/1` to render export cards

**File:** `lib/destila_web/components/chat_components.ex`

Replace the current `chat_message/1` (lines 277-281):

```elixir
# Before:
def chat_message(assigns) do
  processed = ResponseProcessor.process_message(assigns.message, assigns.workflow_session)
  assigns = assign(assigns, :message, processed)
  render_chat_message(assigns)
end

# After:
def chat_message(assigns) do
  processed = ResponseProcessor.process_message(assigns.message, assigns.workflow_session)

  assigns =
    assigns
    |> assign(:message, processed)
    |> assign(:exports, processed[:exports] || [])

  ~H"""
  {render_chat_message(assigns)}
  <%= for {export, idx} <- Enum.with_index(@exports) do %>
    <%= if (export.type || "text") == "markdown" do %>
      <.markdown_card
        id={"export-md-#{@message.id}-#{idx}"}
        key={export.key}
        content={export.value}
      />
    <% else %>
      <.plain_card
        id={"export-plain-#{@message.id}-#{idx}"}
        key={export.key}
        content={export.value}
      />
    <% end %>
  <% end %>
  """
end
```

`render_chat_message(assigns)` returns a `Phoenix.LiveView.Rendered` struct, which can be embedded in HEEx via `{...}`. The `assigns` variable in the template refers to the rebound assigns map (with `:message`, `:exports`, etc.).

### Step 8: Remove the `:generated_prompt` render branch

**File:** `lib/destila_web/components/chat_components.ex`

Delete the entire `render_chat_message(%{message: %{message_type: :generated_prompt}})` function clause (lines 331-467). This includes the template AND the colocated `.PromptCard` hook script.

The `.MarkdownCard` hook (from Step 5) replaces `.PromptCard` with identical behavior under a new name. The card is now rendered via the export card loop in Step 7 rather than as a special message type.

### Step 9: Update `humanize_key` to title-case in the sidebar

**File:** `lib/destila_web/live/workflow_runner_live.ex`

```elixir
# Before (lines 770-772):
defp humanize_key(key) when is_binary(key) do
  key |> String.replace("_", " ") |> String.capitalize()
end

# After:
defp humanize_key(key) when is_binary(key) do
  key
  |> String.split("_")
  |> Enum.map_join(" ", &String.capitalize/1)
end
```

### Step 10: Update feature files

**10a. Rename and rewrite** `features/generated_prompt_viewing.feature` to `features/markdown_metadata_viewing.feature`:

```gherkin
Feature: Markdown Metadata Viewing
  When a workflow exports markdown-type metadata, it is displayed inline
  in the chat using the markdown card component. Users can toggle between
  a rendered HTML view and a raw markdown view, and copy the markdown to
  their clipboard for use in external tools. The card header shows the
  humanized metadata key name.

  Background:
    Given I am logged in
    And a session has exported markdown metadata

  Scenario: Default to rendered HTML view
    Then the markdown card should display the rendered HTML view
    And the card header should show the humanized metadata key
    And the card header should show a copy button

  Scenario: Toggle to markdown view
    When I click the "Markdown" toggle
    Then the metadata should be displayed as raw markdown in a monospace code block
    And the "Markdown" toggle should be active

  Scenario: Toggle back to rendered view
    Given I am viewing the markdown view
    When I click the "Rendered" toggle
    Then the markdown card should display the rendered HTML view
    And the "Rendered" toggle should be active

  Scenario: Copy markdown to clipboard
    When I click the copy button
    Then the raw markdown should be copied to the clipboard
    And the copy button should briefly show a confirmation icon

  Scenario: Copy works from either view
    Given I am viewing the rendered HTML view
    When I click the copy button
    Then the raw markdown should be copied to the clipboard
    When I toggle to the markdown view
    And I click the copy button
    Then the raw markdown should be copied to the clipboard
```

**10b. Add inline chat scenarios** to `features/exported_metadata.feature`:

Append after the existing "Sidebar collapse state persists" scenario:

```gherkin
  # --- Inline Chat Messages ---

  Scenario: Markdown metadata appears as inline chat message
    Given I am on a session detail page
    And the AI exports metadata with type "markdown"
    Then a chat message should appear with the markdown card component
    And the card header should show the humanized metadata key
    And the card should have "Rendered" and "Markdown" tabs
    And the card should have a copy button

  Scenario: Non-markdown metadata appears as inline chat message
    Given I am on a session detail page
    And the AI exports metadata with type "text"
    Then a chat message should appear as a styled card
    And the card should show the humanized metadata key
    And the card should display the metadata value
    And the card should have a copy button
    But the card should not have view-mode tabs

  Scenario: Inline chat message appears in real-time
    Given I am on a session detail page
    And the session is actively processing
    When the AI exports new metadata
    Then the metadata chat message should appear in the conversation
    And the sidebar should also update with the new entry
```

### Step 11: Update tests

**11a. File:** `test/destila/ai/response_processor_test.exs`

Add `alias Destila.AI.Message` at the top (after the existing `alias ResponseProcessor` line).

Add a new `describe` block for `process_message/2` exports. Note: `Message` is an Ecto schema but can be constructed directly with `%Message{}` for unit tests — `process_message/2` only reads struct fields, it doesn't hit the DB. The `workflow_session` parameter only needs `:workflow_type` (accessed by `derive_message_type`).

```elixir
describe "process_message/2 exports" do
  test "includes exports from AI response with export tool calls" do
    msg = %Message{
      id: Ecto.UUID.generate(),
      role: :system,
      phase: 1,
      content: "Here's your prompt.",
      raw_response: %{
        "mcp_tool_uses" => [
          %{
            "name" => "mcp__destila__session",
            "input" => %{
              "action" => "export",
              "key" => "generated_prompt",
              "value" => "# Prompt",
              "type" => "markdown"
            }
          }
        ]
      },
      inserted_at: DateTime.utc_now()
    }

    ws = %{workflow_type: :brainstorm_idea}
    processed = ResponseProcessor.process_message(msg, ws)

    assert [%{key: "generated_prompt", value: "# Prompt", type: "markdown"}] = processed.exports
  end

  test "exports is empty list for user messages" do
    msg = %Message{
      id: Ecto.UUID.generate(),
      role: :user,
      phase: 1,
      content: "Hello",
      inserted_at: DateTime.utc_now()
    }

    processed = ResponseProcessor.process_message(msg, %{})
    assert processed.exports == []
  end

  test "exports is empty list for messages without export tool calls" do
    msg = %Message{
      id: Ecto.UUID.generate(),
      role: :system,
      phase: 1,
      content: "Just text",
      raw_response: %{"mcp_tool_uses" => []},
      inserted_at: DateTime.utc_now()
    }

    ws = %{workflow_type: :brainstorm_idea}
    processed = ResponseProcessor.process_message(msg, ws)
    assert processed.exports == []
  end

  test "multiple exports from a single message" do
    msg = %Message{
      id: Ecto.UUID.generate(),
      role: :system,
      phase: 1,
      content: "Exported two things.",
      raw_response: %{
        "mcp_tool_uses" => [
          %{
            "name" => "mcp__destila__session",
            "input" => %{"action" => "export", "key" => "summary", "value" => "A summary", "type" => "text"}
          },
          %{
            "name" => "mcp__destila__session",
            "input" => %{"action" => "export", "key" => "doc", "value" => "# Doc", "type" => "markdown"}
          }
        ]
      },
      inserted_at: DateTime.utc_now()
    }

    ws = %{workflow_type: :brainstorm_idea}
    processed = ResponseProcessor.process_message(msg, ws)

    assert length(processed.exports) == 2
    assert Enum.at(processed.exports, 0).key == "summary"
    assert Enum.at(processed.exports, 1).key == "doc"
  end
end
```

**11b.** Add a test verifying that `:generated_prompt` message_type is no longer derived:

```elixir
describe "process_message/2 message_type" do
  test "does not derive :generated_prompt from phase config" do
    msg = %Message{
      id: Ecto.UUID.generate(),
      role: :system,
      phase: 4,
      content: "Final prompt content",
      raw_response: %{"mcp_tool_uses" => []},
      inserted_at: DateTime.utc_now()
    }

    # Phase 4 of brainstorm_idea was previously :generated_prompt
    ws = %{workflow_type: :brainstorm_idea}
    processed = ResponseProcessor.process_message(msg, ws)

    assert processed.message_type == nil
  end
end
```

**11c. Rename and rewrite** `test/destila_web/live/generated_prompt_viewing_live_test.exs`

This test file requires a full rewrite, not just tag updates. The key changes:

1. **Rename** the file to `test/destila_web/live/markdown_metadata_viewing_live_test.exs`
2. **Rename** the module to `DestilaWeb.MarkdownMetadataViewingLiveTest`
3. **Update** the `@moduledoc` and `@feature` to reference the new feature file
4. **Rewrite `create_session_with_generated_prompt`** → `create_session_with_markdown_export`: The existing setup creates messages with `"mcp_tool_uses" => []` (empty). With the new export-detection approach, **no inline cards will render** for messages with empty tool uses. The setup must include an export tool call in `raw_response`:

```elixir
defp create_session_with_markdown_export do
  {:ok, workflow_session} =
    Destila.Workflows.insert_workflow_session(%{
      title: "Test Session",
      workflow_type: :brainstorm_idea,
      project_id: nil,
      done_at: DateTime.utc_now(),
      current_phase: 4,
      total_phases: 4
    })

  {:ok, ai_session} = Destila.AI.get_or_create_ai_session(workflow_session.id)

  {:ok, _} =
    Destila.AI.create_message(ai_session.id, %{
      role: :system,
      content: "Here is your implementation prompt.",
      raw_response: %{
        "text" => "Here is your implementation prompt.",
        "result" => "Here is your implementation prompt.",
        "mcp_tool_uses" => [
          %{
            "name" => "mcp__destila__session",
            "input" => %{
              "action" => "export",
              "key" => "generated_prompt",
              "value" => @sample_markdown,
              "type" => "markdown"
            }
          }
        ],
        "is_error" => false
      },
      phase: 4,
      workflow_session_id: workflow_session.id
    })

  workflow_session
end
```

5. **Update all CSS selectors** in assertions to match new component markup:

| Old selector | New selector |
|---|---|
| `[id^='prompt-card-']` | `[id^='export-md-']` |
| `button.prompt-copy-btn` | `button.md-card-copy-btn` |
| `.prompt-tab` | `.md-card-tab` |

6. **Update tag values** from `@feature "generated_prompt_viewing"` to `@feature "markdown_metadata_viewing"`

The full rewritten test file:

```elixir
defmodule DestilaWeb.MarkdownMetadataViewingLiveTest do
  @moduledoc """
  LiveView tests for Markdown Metadata Viewing.
  Feature: features/markdown_metadata_viewing.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "markdown_metadata_viewing"

  @sample_markdown """
  # Implementation Prompt

  ## Overview

  Fix the login timeout bug by increasing the session TTL.

  ## Steps

  1. Update `config/runtime.exs`
  2. Change `session_ttl` from 30 to 60 minutes
  3. Add a test for the new timeout value

  ```elixir
  config :my_app, session_ttl: :timer.minutes(60)
  ```
  """

  setup %{conn: conn} do
    ClaudeCode.Test.set_mode_to_shared()

    ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
      [
        ClaudeCode.Test.text("AI response"),
        ClaudeCode.Test.result("AI response")
      ]
    end)

    conn = post(conn, "/login", %{"email" => "test@example.com"})
    {:ok, conn: conn}
  end

  defp create_session_with_markdown_export do
    {:ok, workflow_session} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test Session",
        workflow_type: :brainstorm_idea,
        project_id: nil,
        done_at: DateTime.utc_now(),
        current_phase: 4,
        total_phases: 4
      })

    {:ok, ai_session} = Destila.AI.get_or_create_ai_session(workflow_session.id)

    {:ok, _} =
      Destila.AI.create_message(ai_session.id, %{
        role: :system,
        content: "Here is your implementation prompt.",
        raw_response: %{
          "text" => "Here is your implementation prompt.",
          "result" => "Here is your implementation prompt.",
          "mcp_tool_uses" => [
            %{
              "name" => "mcp__destila__session",
              "input" => %{
                "action" => "export",
                "key" => "generated_prompt",
                "value" => @sample_markdown,
                "type" => "markdown"
              }
            }
          ],
          "is_error" => false
        },
        phase: 4,
        workflow_session_id: workflow_session.id
      })

    workflow_session
  end

  describe "default rendered view" do
    @tag feature: @feature, scenario: "Default to rendered HTML view"
    test "renders the markdown card with toggle buttons and copy button", %{conn: conn} do
      ws = create_session_with_markdown_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      # Card exists with export-md ID prefix and data-content
      assert has_element?(view, "[id^='export-md-']")
      assert has_element?(view, "[data-content]")

      # Toggle buttons present with tablist
      assert has_element?(view, "[role='tablist']")
      assert has_element?(view, "button[data-view='rendered']")
      assert has_element?(view, "button[data-view='markdown']")

      # Copy button present
      assert has_element?(view, "button.md-card-copy-btn")

      # Both view containers present
      assert has_element?(view, "[data-rendered]")
      assert has_element?(view, "[data-markdown]")

      # Rendered view has prose wrapper
      assert has_element?(view, "[data-rendered].prose")

      # Markdown view has pre/code block
      assert has_element?(view, "[data-markdown] pre code")

      # Card header shows humanized key
      html = render(view)
      assert html =~ "Generated Prompt"
    end
  end

  describe "markdown view structure" do
    @tag feature: @feature, scenario: "Toggle to markdown view"
    test "markdown view contains raw markdown in pre/code block", %{conn: conn} do
      ws = create_session_with_markdown_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      code_html = view |> element("[data-markdown] pre code") |> render()
      assert code_html =~ "# Implementation Prompt"
      assert code_html =~ "## Overview"
      assert code_html =~ "```elixir"
    end
  end

  describe "rendered view structure" do
    @tag feature: @feature, scenario: "Toggle back to rendered view"
    test "rendered view contains HTML-rendered markdown", %{conn: conn} do
      ws = create_session_with_markdown_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "[data-rendered] h1")
      assert has_element?(view, "[data-rendered] h2")
    end
  end

  describe "copy button" do
    @tag feature: @feature, scenario: "Copy markdown to clipboard"
    test "copy button has correct aria-label and icon", %{conn: conn} do
      ws = create_session_with_markdown_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "button[aria-label='Copy markdown to clipboard']")
      assert has_element?(view, "button.md-card-copy-btn .hero-clipboard-document-micro")
    end

    @tag feature: @feature, scenario: "Copy works from either view"
    test "data-content attribute contains the raw markdown for JS hook", %{conn: conn} do
      ws = create_session_with_markdown_export()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      card_html = view |> element("[id^='export-md-']") |> render()
      assert card_html =~ "data-content=\""
      assert card_html =~ "# Implementation Prompt"
    end
  end
end
```

### Step 12: Run `mix precommit`

Verify compilation, formatting, and all tests pass.

## What does NOT change

- **Sidebar**: The right sidebar continues to display exported metadata exactly as before. Both sidebar and inline cards coexist.
- **Database schema**: No migration. Export detection reads from the existing `raw_response` JSON column.
- **Metadata persistence**: The `conversation.ex` export processing flow is unchanged. Metadata is still persisted via `upsert_metadata/5`.
- **PubSub updates**: `:metadata_updated` broadcast still triggers sidebar refresh. Inline cards are rendered from messages (which also update via PubSub).
- **`brainstorm_idea_workflow.feature`**: No changes needed. "The prompt should be displayed in a styled card" is still true — the card is now driven by export detection rather than phase config.
- **Other workflows**: `implement_general_prompt` and `code_chat` workflows don't use `message_type` on phases. They export metadata via the session tool, and those exports will now also get inline cards automatically.

## Execution order

1. Steps 1-2 (ResponseProcessor) — add exports field, remove :generated_prompt detection + dead code (`phase_def`, `get_phase_def/2`)
2. Step 3 (Phase struct + workflow) — remove message_type field and usage
3. Steps 4-6 (ChatComponents) — add humanize_key, create markdown_card and plain_card
4. Steps 7-8 (ChatComponents) — update chat_message, remove old :generated_prompt handler
5. Step 9 (LiveView) — update humanize_key to title-case
6. Step 10 (Feature files) — rename and update Gherkin scenarios
7. Step 11 (Tests) — add/update tests
8. Step 12 (Precommit) — validate

## Files modified

- `lib/destila/ai/response_processor.ex` — add exports to process_message, remove :generated_prompt detection, remove dead `phase_def`/`get_phase_def` code
- `lib/destila/workflows/phase.ex` — remove :message_type field from struct
- `lib/destila/workflows/brainstorm_idea_workflow.ex` — remove message_type from Phase 4
- `lib/destila_web/components/chat_components.ex` — add humanize_key, markdown_card, plain_card, .MarkdownCard/.PlainCard hooks; update chat_message; remove :generated_prompt handler and .PromptCard hook
- `lib/destila_web/live/workflow_runner_live.ex` — update humanize_key to title-case
- `features/generated_prompt_viewing.feature` — deleted (renamed)
- `features/markdown_metadata_viewing.feature` — new file (renamed + rewritten)
- `features/exported_metadata.feature` — add inline chat message scenarios
- `test/destila/ai/response_processor_test.exs` — add process_message exports tests, add message_type regression test
- `test/destila_web/live/generated_prompt_viewing_live_test.exs` — deleted (renamed)
- `test/destila_web/live/markdown_metadata_viewing_live_test.exs` — new file (renamed + rewritten with export tool calls in raw_response and updated CSS selectors)

## Done when

- AI responses with export tool calls show inline metadata cards after the message bubble
- Markdown exports render with rendered/raw toggle tabs and copy button (`.MarkdownCard` hook)
- Non-markdown exports render with the value and copy button only (`.PlainCard` hook)
- Card headers show the humanized, title-cased metadata key
- The phase-level `message_type: :generated_prompt` mechanism is fully removed
- The `:message_type` field is removed from the `Phase` struct
- The sidebar continues to work unchanged
- `humanize_key` produces title-case in both sidebar and inline cards
- Feature files are updated (renamed + new inline scenarios)
- All tests pass, `mix precommit` passes
