---
title: "feat: Markdown modal from sidebar"
type: feat
date: 2026-04-09
---

# feat: Markdown modal from sidebar

## Overview

Change the exported metadata sidebar so markdown-type entries display as a clickable button with an icon (matching the video entry style) instead of the expandable `<details>` block. Clicking opens a full-screen modal overlay — identical in style to the video modal — showing the markdown content with dual "Rendered"/"Markdown" tabs and a copy-to-clipboard button.

Additionally, extract the markdown rendering logic from `markdown_card` into a shared component so both the inline chat card and the new modal can use it without duplication.

## Current state

- **Sidebar rendering** (`lib/destila_web/live/workflow_runner_live.ex:620-662`): The `for` loop checks `Map.has_key?(meta.value, "video_file")` — video entries get a button+icon row with `open_video_modal`; everything else (including markdown) falls into a `<details>` block with `metadata_value_block/1` that shows escaped text.
- **Video modal** (`workflow_runner_live.ex:66, 288-294, 684-706`): Uses `@video_modal_meta_id` assign, `open_video_modal`/`close_video_modal` events, and a `fixed inset-0 z-50` overlay with `bg-black/70 backdrop-blur-sm`, centered content, close button at `-top-10 right-0`.
- **`markdown_card`** (`chat_components.ex:420-560`): A private component with header (humanized key, tab buttons, copy button), rendered HTML view, raw markdown view, and the `.MarkdownCard` colocated JS hook handling tab switching and clipboard copy.
- **`markdown_to_html/1`** (`chat_components.ex:10-22`): Private function using Earmark + HtmlSanitizeEx. Only used within `ChatComponents`.
- **Existing tests** (`test/destila_web/live/markdown_metadata_viewing_live_test.exs`): Tests the inline `markdown_card` — checks for `[id^='export-md-']`, `[data-content]`, `[role='tablist']`, tabs, copy button, `[data-rendered]`, `[data-markdown]`, prose class, `pre code` block, and humanized key text.
- **Feature files**: `features/markdown_metadata_viewing.feature` (40 lines, 5 scenarios about inline card) and `features/exported_metadata.feature` (98 lines, includes video sidebar scenario but no markdown sidebar scenario).
- **Metadata value map structure**: The `value` column is a map where the key is the type string — `%{"markdown" => "# content"}`, `%{"video_file" => "/path"}`, `%{"text" => "plain"}`. The sidebar can detect markdown entries via `Map.has_key?(meta.value, "markdown")`.

## Key design decisions

### 1. Shared `markdown_viewer` component

Extract the markdown rendering body (tab buttons, rendered HTML pane, raw markdown pane, copy button, `data-content` attribute) from `markdown_card` into a new private component `markdown_viewer` in `chat_components.ex`. This component contains only the inner rendering and the `.MarkdownCard` JS hook — no card frame, no avatar, no header with the key name.

**`markdown_viewer` attrs:**
- `id` (string, required) — used for DOM id and the `phx-hook` binding
- `content` (string, required) — raw markdown text

**`markdown_card` refactored:** Keeps the outer frame (avatar, bordered card, header bar with humanized key) and calls `<.markdown_viewer>` inside the card body.

**Modal usage:** The modal template in `workflow_runner_live.ex` calls `<.markdown_viewer>` directly inside the overlay content area, with its own header showing the humanized key.

The `.MarkdownCard` colocated JS hook stays attached to `markdown_viewer` and continues to work — it queries for `.md-card-tab` and `.md-card-copy-btn` within `this.el`, which will be the `markdown_viewer` root element in both contexts.

### 2. Markdown modal follows video modal pattern exactly

Add `@markdown_modal_meta_id` assign (initially `nil`), `open_markdown_modal`/`close_markdown_modal` event handlers, and a conditional modal template. The modal:

- Uses `fixed inset-0 z-50 flex items-center justify-center`
- Dark backdrop: `absolute inset-0 bg-black/70 backdrop-blur-sm` with `phx-click="close_markdown_modal"`
- Content container: `relative z-10 w-full max-w-3xl mx-4`
- Close button: `absolute -top-10 right-0 text-white/70 hover:text-white`
- Content: a card with the humanized key as header, then `<.markdown_viewer>` inside

To render the content, the modal looks up the metadata record from `@exported_metadata` by ID and extracts the markdown content from `meta.value["markdown"]`.

### 3. Sidebar entry for markdown matches video style

For markdown entries (`Map.has_key?(meta.value, "markdown")`), render a row identical to the video entry structure:
- Icon: `hero-document-text-micro` (document icon, analogous to `hero-film-micro` for video)
- Humanized key name (truncated, flex-1)
- Button with `hero-eye-micro` icon (view action, analogous to `hero-play-micro` for video) that fires `open_markdown_modal` with the metadata ID

Non-markdown, non-video entries keep the existing `<details>` block.

### 4. JS hook reuse

The `.MarkdownCard` colocated hook is defined inside `markdown_card`'s template. After extraction to `markdown_viewer`, the hook definition moves there. Phoenix colocated hooks are deduplicated by name — the same `.MarkdownCard` hook handles all instances (inline card and modal). When the modal is conditionally rendered and mounts a new `markdown_viewer`, the hook's `mounted()` callback runs and sets up tab switching and copy for that instance.

## Changes

### Step 1: Extract `markdown_viewer` from `markdown_card`

**File:** `lib/destila_web/components/chat_components.ex`

Create a new private component `markdown_viewer` with the inner rendering logic. Place it right before the existing `markdown_card` (before line 420).

**`markdown_viewer` component:**

```elixir
attr :id, :string, required: true
attr :content, :string, required: true

defp markdown_viewer(assigns) do
  ~H"""
  <div
    id={@id}
    class="overflow-hidden"
    phx-hook=".MarkdownCard"
    data-content={@content}
  >
    <div class="flex items-center justify-end gap-1 px-4 py-2">
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
    <div data-rendered class="px-4 py-3 text-sm text-base-content prose prose-sm max-w-none">
      {raw(markdown_to_html(@content))}
    </div>
    <div data-markdown class="hidden px-4 py-3">
      <pre class="text-sm font-mono text-base-content whitespace-pre-wrap break-words bg-base-300/30 rounded-lg p-3 overflow-x-auto"><code>{@content}</code></pre>
    </div>
  </div>
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
  """
end
```

**Refactored `markdown_card`:**

The card keeps its outer frame and header, but calls `<.markdown_viewer>` for the inner content. The header now only contains the humanized key label (the tabs and copy button move into `markdown_viewer`):

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
      <div class="rounded-2xl border-2 border-primary/20 bg-base-200 overflow-hidden">
        <div class="px-4 py-2 bg-primary/10 border-b border-primary/20">
          <span class="text-xs font-medium text-primary uppercase tracking-wide">
            {humanize_key(@key)}
          </span>
        </div>
        <.markdown_viewer id={@id} content={@content} />
      </div>
    </div>
  </div>
  """
end
```

**Important:** The `phx-hook` and `data-content` attributes move from the card's outer div to the `markdown_viewer` root div. The `id` attr moves to `markdown_viewer`. The card's outer div no longer needs `id`, `phx-hook`, or `data-content`.

### Step 2: Make `markdown_viewer` public for cross-module use

**File:** `lib/destila_web/components/chat_components.ex`

Change `defp markdown_viewer` to `def markdown_viewer` so it can be called from `workflow_runner_live.ex` (which already does `import DestilaWeb.ChatComponents`).

Keep `markdown_card` as `defp` — it's only used within `chat_components.ex`.

### Step 3: Add `@markdown_modal_meta_id` assign

**File:** `lib/destila_web/live/workflow_runner_live.ex`

Add to the assign chain in `mount_session/2` at line 66, right after the `video_modal_meta_id` assign:

```elixir
|> assign(:markdown_modal_meta_id, nil)
```

### Step 4: Add open/close event handlers

**File:** `lib/destila_web/live/workflow_runner_live.ex`

Add right after the `close_video_modal` handler (after line 294):

```elixir
def handle_event("open_markdown_modal", %{"id" => id}, socket) do
  {:noreply, assign(socket, :markdown_modal_meta_id, id)}
end

def handle_event("close_markdown_modal", _params, socket) do
  {:noreply, assign(socket, :markdown_modal_meta_id, nil)}
end
```

### Step 5: Replace sidebar `<details>` for markdown entries

**File:** `lib/destila_web/live/workflow_runner_live.ex`

Replace the `else` branch (lines 643-661) of the sidebar metadata loop to add a middle branch for markdown. The sidebar loop becomes a three-way conditional:

```heex
<div class="space-y-1.5">
  <%= for meta <- @exported_metadata do %>
    <%= cond do %>
      <% Map.has_key?(meta.value, "video_file") -> %>
        <div
          id={"metadata-entry-#{meta.id}"}
          class="flex items-center gap-2 px-3 py-2 rounded-lg border border-base-300/60 hover:bg-base-200/50 transition-colors duration-150"
        >
          <.icon
            name="hero-film-micro"
            class="size-3 text-base-content/30 shrink-0"
          />
          <span class="font-medium text-sm text-base-content/70 truncate flex-1">
            {humanize_key(meta.key)}
          </span>
          <button
            phx-click="open_video_modal"
            phx-value-id={meta.id}
            class="p-1 rounded-md hover:bg-base-300/50 transition-colors"
            aria-label={"Play #{humanize_key(meta.key)}"}
          >
            <.icon name="hero-play-micro" class="size-4 text-primary" />
          </button>
        </div>
      <% Map.has_key?(meta.value, "markdown") -> %>
        <div
          id={"metadata-entry-#{meta.id}"}
          class="flex items-center gap-2 px-3 py-2 rounded-lg border border-base-300/60 hover:bg-base-200/50 transition-colors duration-150"
        >
          <.icon
            name="hero-document-text-micro"
            class="size-3 text-base-content/30 shrink-0"
          />
          <span class="font-medium text-sm text-base-content/70 truncate flex-1">
            {humanize_key(meta.key)}
          </span>
          <button
            phx-click="open_markdown_modal"
            phx-value-id={meta.id}
            class="p-1 rounded-md hover:bg-base-300/50 transition-colors"
            aria-label={"View #{humanize_key(meta.key)}"}
          >
            <.icon name="hero-eye-micro" class="size-4 text-primary" />
          </button>
        </div>
      <% true -> %>
        <details
          id={"metadata-entry-#{meta.id}"}
          class="group rounded-lg border border-base-300/60 overflow-hidden"
          open
        >
          <summary class="flex items-center gap-2 cursor-pointer px-3 py-2 hover:bg-base-200/50 transition-colors duration-150 text-sm select-none">
            <.icon
              name="hero-chevron-right-micro"
              class="size-3 text-base-content/30 group-open:rotate-90 transition-transform duration-150 shrink-0"
            />
            <span class="font-medium text-base-content/70 truncate">
              {humanize_key(meta.key)}
            </span>
          </summary>
          <div class="border-t border-base-300/40 bg-base-200/30">
            <.metadata_value_block value={meta.value} />
          </div>
        </details>
    <% end %>
  <% end %>
</div>
```

### Step 6: Add markdown modal template

**File:** `lib/destila_web/live/workflow_runner_live.ex`

Insert right after the video modal (after line 706), before the `.MetadataSidebar` hook script:

```heex
<%!-- Markdown modal --%>
<%= if @markdown_modal_meta_id do %>
  <% modal_meta = Enum.find(@exported_metadata, &(&1.id == @markdown_modal_meta_id)) %>
  <div
    id="markdown-modal"
    class="fixed inset-0 z-50 flex items-center justify-center"
  >
    <div
      class="absolute inset-0 bg-black/70 backdrop-blur-sm"
      phx-click="close_markdown_modal"
    />
    <div class="relative z-10 w-full max-w-3xl mx-4">
      <button
        phx-click="close_markdown_modal"
        class="absolute -top-10 right-0 text-white/70 hover:text-white transition-colors"
        aria-label="Close markdown"
      >
        <.icon name="hero-x-mark" class="size-6" />
      </button>
      <div class="rounded-xl bg-base-200 shadow-2xl overflow-hidden">
        <div class="px-4 py-2 bg-primary/10 border-b border-primary/20">
          <span class="text-xs font-medium text-primary uppercase tracking-wide">
            {humanize_key(modal_meta.key)}
          </span>
        </div>
        <.markdown_viewer
          id="markdown-modal-viewer"
          content={modal_meta.value["markdown"]}
        />
      </div>
    </div>
  </div>
<% end %>
```

Note: Uses `<%= if ... do %>` with a local variable (`modal_meta`) to look up the metadata record by ID. The `<.markdown_viewer>` gets a fixed ID (`"markdown-modal-viewer"`) distinct from any inline card IDs.

### Step 7: Update feature files

**File:** `features/markdown_metadata_viewing.feature`

Update the feature description (lines 1-6) and add new scenarios at the end:

Updated description:
```gherkin
Feature: Markdown Metadata Viewing
  When a workflow exports markdown-type metadata, it is displayed inline
  in the chat using the markdown card component and can be opened in a
  full-screen modal from the metadata sidebar. Users can toggle between
  a rendered HTML view and a raw markdown view, and copy the markdown to
  their clipboard. The card header shows the humanized metadata key name.
```

New scenarios (append after line 40):
```gherkin

  Scenario: Open markdown in modal from sidebar
    When I click the view button on the sidebar markdown entry
    Then a full-screen modal overlay should appear with a dark backdrop
    And the modal should display the markdown with "Rendered" and "Markdown" tabs
    And the modal should default to the rendered HTML view
    And the modal should have a copy button

  Scenario: Toggle views in markdown modal
    Given the markdown modal is open
    When I click the "Markdown" tab in the modal
    Then the modal should display raw markdown in a monospace code block
    When I click the "Rendered" tab in the modal
    Then the modal should display the rendered HTML view

  Scenario: Copy markdown from modal
    Given the markdown modal is open
    When I click the copy button in the modal
    Then the raw markdown should be copied to the clipboard
    And the copy button should briefly show a confirmation icon

  Scenario: Close markdown modal
    Given the markdown modal is open
    When I close the modal
    Then the modal should disappear
    And the inline markdown card in the chat should still be visible
```

**File:** `features/exported_metadata.feature`

Add after the video sidebar scenario (after line 98):

```gherkin

  Scenario: Markdown metadata sidebar entry has view button
    Given I am on a session detail page
    And the session has exported metadata of type "markdown"
    Then the sidebar entry should display a view button instead of an expandable text preview
    When I click the view button
    Then a modal overlay should open with the rendered markdown
```

### Step 8: Write tests

**File:** `test/destila_web/live/markdown_metadata_viewing_live_test.exs`

Add new test blocks at the end of the module (before the final `end`). These test the sidebar button and modal. The existing `create_session_with_markdown_export/0` helper already creates the necessary data.

```elixir
describe "sidebar entry" do
  @tag feature: "exported_metadata", scenario: "Markdown metadata sidebar entry has view button"
  test "markdown entry shows view button instead of details block", %{conn: conn} do
    ws = create_session_with_markdown_export()
    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    # Should have a view button, not a details/summary
    assert has_element?(view, "button[phx-click='open_markdown_modal']")
    refute has_element?(view, "details[id^='metadata-entry-']")

    # Should show document icon
    assert has_element?(view, "[id^='metadata-entry-'] .hero-document-text-micro")
  end
end

describe "markdown modal" do
  @tag feature: @feature, scenario: "Open markdown in modal from sidebar"
  test "clicking sidebar view button opens markdown modal", %{conn: conn} do
    ws = create_session_with_markdown_export()
    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    view |> element("button[phx-click='open_markdown_modal']") |> render_click()

    assert has_element?(view, "#markdown-modal")
    assert has_element?(view, "#markdown-modal-viewer")
    # Modal has tabs and copy button
    assert has_element?(view, "#markdown-modal-viewer [role='tablist']")
    assert has_element?(view, "#markdown-modal-viewer button[data-view='rendered']")
    assert has_element?(view, "#markdown-modal-viewer button[data-view='markdown']")
    assert has_element?(view, "#markdown-modal-viewer .md-card-copy-btn")
    # Modal has rendered and raw views
    assert has_element?(view, "#markdown-modal-viewer [data-rendered]")
    assert has_element?(view, "#markdown-modal-viewer [data-markdown]")
  end

  @tag feature: @feature, scenario: "Open markdown in modal from sidebar"
  test "modal shows humanized key in header", %{conn: conn} do
    ws = create_session_with_markdown_export()
    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    view |> element("button[phx-click='open_markdown_modal']") |> render_click()

    modal_html = view |> element("#markdown-modal") |> render()
    assert modal_html =~ "Generated Prompt"
  end

  @tag feature: @feature, scenario: "Close markdown modal"
  test "clicking close button dismisses the modal", %{conn: conn} do
    ws = create_session_with_markdown_export()
    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    view |> element("button[phx-click='open_markdown_modal']") |> render_click()
    assert has_element?(view, "#markdown-modal")

    view |> element("#markdown-modal button[phx-click='close_markdown_modal']") |> render_click()
    refute has_element?(view, "#markdown-modal")
  end

  @tag feature: @feature, scenario: "Close markdown modal"
  test "inline markdown card remains after closing modal", %{conn: conn} do
    ws = create_session_with_markdown_export()
    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    view |> element("button[phx-click='open_markdown_modal']") |> render_click()
    view |> element("#markdown-modal button[phx-click='close_markdown_modal']") |> render_click()

    # Inline card still present
    assert has_element?(view, "[id^='export-md-']")
  end
end
```

### Step 9: Verify existing tests pass

Run `mix test test/destila_web/live/markdown_metadata_viewing_live_test.exs` to ensure the existing inline card tests still pass after the `markdown_card` → `markdown_viewer` extraction. Key things to verify:

- `[id^='export-md-']` — the ID is now on the `markdown_viewer` root div (was on the card's inner div), so this selector should still match.
- `[data-content]` — moved to `markdown_viewer` root div, still matches.
- `[role='tablist']`, tab buttons, copy button — now inside `markdown_viewer`, still match.
- `[data-rendered]`, `[data-markdown]` — unchanged, still inside `markdown_viewer`.
- `[data-rendered].prose` — the prose class is on the `[data-rendered]` div inside `markdown_viewer`, still matches.
- `[data-markdown] pre code` — unchanged.

The `phx-hook=".MarkdownCard"` attribute is now on the `markdown_viewer` root div. Since the hook uses `this.el` to scope queries, and the tabs/copy/views are children of that element, the hook works in both contexts.

## File summary

| File | Action | Description |
|------|--------|-------------|
| `lib/destila_web/components/chat_components.ex` | Edit | Extract `markdown_viewer` from `markdown_card`; make it public |
| `lib/destila_web/live/workflow_runner_live.ex` | Edit | Add `@markdown_modal_meta_id` assign, open/close events, sidebar markdown button, modal template |
| `features/markdown_metadata_viewing.feature` | Edit | Update description, add 4 modal scenarios |
| `features/exported_metadata.feature` | Edit | Add markdown sidebar view button scenario |
| `test/destila_web/live/markdown_metadata_viewing_live_test.exs` | Edit | Add sidebar and modal test blocks |
