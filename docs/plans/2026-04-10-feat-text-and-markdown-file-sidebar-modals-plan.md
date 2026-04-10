# Plan: text_file and markdown_file sidebar modals

## Goal

Add modal viewers for `text_file` and `markdown_file` exported metadata in the right-side panel (metadata sidebar). Currently `text_file` falls through to the generic `<details>` fallback showing just the file path, and `markdown_file` does not exist as a type. After this change:

- **text_file** entries show a clickable sidebar row (icon + eye button) that opens a modal displaying the file's content as plain text
- **markdown_file** entries show a clickable sidebar row (icon + eye button) that opens a modal displaying the file's content using the existing `markdown_viewer` component

Both follow the established patterns for `video_file` and `markdown` sidebar entries.

## Context

- `video_file` sidebar entry: film icon → play button → opens video modal (`workflow_runner_live.ex:704-725`)
- `markdown` sidebar entry: document icon → eye button → opens markdown modal (`workflow_runner_live.ex:726-746`)
- Text/other types: fall through to `<details>` collapsible showing raw value (`workflow_runner_live.ex:747-765`)
- Valid metadata types: `@valid_metadata_types ~w(text text_file markdown video_file)` in `workflows.ex:12`
- The existing markdown modal reads content from the metadata value map (inline content); file-based types store a filesystem path instead

## Changes

### 1. Add `markdown_file` to valid metadata types

**File:** `lib/destila/workflows.ex:12`

Add `markdown_file` to the `@valid_metadata_types` module attribute:

```elixir
@valid_metadata_types ~w(text text_file markdown markdown_file video_file)
```

### 2. Add `text_file` and `markdown_file` sidebar entries

**File:** `lib/destila_web/live/workflow_runner_live.ex` — sidebar `cond` block (lines 704-765)

Insert two new clauses before the `true ->` fallback in the exported metadata `cond` block:

**text_file clause** — identical structure to the `markdown` entry but with a document-code icon:

```heex
<% Map.has_key?(meta.value, "text_file") -> %>
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
      phx-click="open_text_file_modal"
      phx-value-id={meta.id}
      class="p-1 rounded-md hover:bg-base-300/50 transition-colors"
      aria-label={"View #{humanize_key(meta.key)}"}
    >
      <.icon name="hero-eye-micro" class="size-4 text-primary" />
    </button>
  </div>
```

**markdown_file clause** — same structure, triggers the markdown modal with file content:

```heex
<% Map.has_key?(meta.value, "markdown_file") -> %>
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
      phx-click="open_markdown_file_modal"
      phx-value-id={meta.id}
      class="p-1 rounded-md hover:bg-base-300/50 transition-colors"
      aria-label={"View #{humanize_key(meta.key)}"}
    >
      <.icon name="hero-eye-micro" class="size-4 text-primary" />
    </button>
  </div>
```

### 3. Add text_file modal template

**File:** `lib/destila_web/live/workflow_runner_live.ex` — after the markdown modal block (after line 839)

Add a new modal that displays plain text content with a copy button. Follows the same full-screen overlay pattern as the video and markdown modals:

```heex
<%!-- Text file modal --%>
<%= if @text_file_modal_content do %>
  <div
    id="text-file-modal"
    class="fixed inset-0 z-50 flex items-center justify-center"
  >
    <div
      class="absolute inset-0 bg-black/70 backdrop-blur-sm"
      phx-click="close_text_file_modal"
    />
    <div class="relative z-10 w-full max-w-3xl mx-4">
      <button
        phx-click="close_text_file_modal"
        class="absolute -top-10 right-0 text-white/70 hover:text-white transition-colors"
        aria-label="Close text file"
      >
        <.icon name="hero-x-mark" class="size-6" />
      </button>
      <div class="rounded-xl bg-base-200 shadow-2xl overflow-hidden max-h-[80vh] flex flex-col">
        <div class="px-4 py-3 bg-base-300/50 border-b border-base-300 flex items-center justify-between">
          <span class="text-sm font-medium text-base-content/70">
            {@text_file_modal_label}
          </span>
        </div>
        <div class="overflow-y-auto p-4">
          <pre class="text-sm text-base-content/80 whitespace-pre-wrap break-words leading-relaxed">{@text_file_modal_content}</pre>
        </div>
      </div>
    </div>
  </div>
<% end %>
```

### 4. Add LiveView assigns and event handlers

**File:** `lib/destila_web/live/workflow_runner_live.ex`

**Mount assigns** (around line 66, alongside existing modal assigns):

```elixir
|> assign(:text_file_modal_content, nil)
|> assign(:text_file_modal_label, nil)
```

**Event handlers** (after the existing `close_markdown_modal` handler, around line 319):

```elixir
def handle_event("open_text_file_modal", %{"id" => id}, socket) do
  meta = Enum.find(socket.assigns.exported_metadata, &(&1.id == id))
  path = meta.value["text_file"]

  case File.read(path) do
    {:ok, content} ->
      {:noreply,
       socket
       |> assign(:text_file_modal_content, content)
       |> assign(:text_file_modal_label, humanize_key(meta.key))}

    {:error, _reason} ->
      {:noreply, put_flash(socket, :error, "Could not read file: #{path}")}
  end
end

def handle_event("close_text_file_modal", _params, socket) do
  {:noreply,
   socket
   |> assign(:text_file_modal_content, nil)
   |> assign(:text_file_modal_label, nil)}
end

def handle_event("open_markdown_file_modal", %{"id" => id}, socket) do
  meta = Enum.find(socket.assigns.exported_metadata, &(&1.id == id))
  path = meta.value["markdown_file"]

  case File.read(path) do
    {:ok, content} ->
      {:noreply,
       socket
       |> assign(:markdown_modal_content, content)
       |> assign(:markdown_modal_label, humanize_key(meta.key))}

    {:error, _reason} ->
      {:noreply, put_flash(socket, :error, "Could not read file: #{path}")}
  end
end
```

Note: `markdown_file` reuses the existing `@markdown_modal_content` / `@markdown_modal_label` assigns and the existing markdown modal template — no new modal template needed for this type. It reads the file from disk and passes the content to the same markdown viewer.

### 5. Add `markdown_file` to format_metadata_value

**File:** `lib/destila_web/live/workflow_runner_live.ex` — `format_metadata_value` (around line 957)

Add a clause for the new type:

```elixir
defp format_metadata_value(%{"markdown_file" => path}) when is_binary(path), do: path
```

### 6. Update feature file

**File:** `features/exported_metadata.feature`

Add two new scenarios after the existing "Markdown metadata sidebar entry has view button" scenario:

```gherkin
  Scenario: Text file metadata sidebar entry has view button
    Given I am on a session detail page
    And the session has exported metadata of type "text_file"
    Then the sidebar entry should display a view button instead of an expandable text preview
    When I click the view button
    Then a modal overlay should open displaying the file's text content

  Scenario: Markdown file metadata sidebar entry has view button
    Given I am on a session detail page
    And the session has exported metadata of type "markdown_file"
    Then the sidebar entry should display a view button instead of an expandable text preview
    When I click the view button
    Then a modal overlay should open with the rendered markdown from the file
```

## Files to modify

| File | Change |
|------|--------|
| `lib/destila/workflows.ex` | Add `markdown_file` to `@valid_metadata_types` |
| `lib/destila_web/live/workflow_runner_live.ex` | Add sidebar entries, modals, assigns, and event handlers |
| `features/exported_metadata.feature` | Add scenarios for text_file and markdown_file sidebar modals |

## Design decisions

1. **File reading happens server-side in the event handler** — since this is a local single-user app, `File.read/1` in the handler is the simplest approach. No HTTP endpoint needed (unlike video which requires streaming/range requests).

2. **markdown_file reuses the existing markdown modal** — the only difference from `markdown` is that content comes from a file path instead of being stored inline. The event handler reads the file and feeds the content to the same `@markdown_modal_content` assign.

3. **text_file gets its own modal** — text content needs a different viewer (plain `<pre>` block) rather than the markdown viewer with tabs and rendering. A simple modal with a header and scrollable pre-formatted text.

4. **No changes to inline chat cards** — the user prompt specifies "Apply this only to the exported metadata (shown in the right side panel)". Inline chat rendering is out of scope.
