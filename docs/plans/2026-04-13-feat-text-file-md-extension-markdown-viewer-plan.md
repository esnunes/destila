# Plan: Use markdown viewer for `.md` text_file metadata

## Goal

When a `text_file` metadata entry has a `.md` file extension, open the markdown modal (with rendered markdown + raw toggle) instead of the plain text modal (with `<pre>` block). This gives `.md` files proper rendering while keeping all other text files displayed as plain text.

## Context

- `text_file` metadata stores a filesystem path in the value map: `%{"text_file" => "/path/to/file.txt"}`
- The `open_text_modal` event handler (`workflow_runner_live.ex:324-345`) reads the file and assigns content to the text modal assigns
- The text modal (`workflow_runner_live.ex:921-951`) renders content in a `<pre>` block — no markdown rendering
- A markdown modal already exists (`workflow_runner_live.ex:892-919`) using the `markdown_viewer` component with rendered/raw tabs and copy button
- The `markdown_file` type already demonstrates the pattern of reading a file and opening the markdown modal (`workflow_runner_live.ex:355-369`)

## Changes

### 1. Update `open_text_modal` event handler to detect `.md` extension

**File:** `lib/destila_web/live/workflow_runner_live.ex:324-345`

In the `%{"text_file" => path}` branch, after successfully reading the file, check if the path ends with `.md`. If so, assign to the markdown modal assigns instead of the text modal assigns:

```elixir
def handle_event("open_text_modal", %{"id" => id}, socket) do
  meta = Enum.find(socket.assigns.exported_metadata, &(&1.id == id))

  case meta.value do
    %{"text_file" => path} ->
      case File.read(path) do
        {:ok, content} ->
          if Path.extname(path) == ".md" do
            {:noreply,
             socket
             |> assign(:markdown_modal_content, content)
             |> assign(:markdown_modal_label, humanize_key(meta.key))}
          else
            {:noreply,
             socket
             |> assign(:text_modal_content, content)
             |> assign(:text_modal_label, humanize_key(meta.key))}
          end

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not read file: #{path}")}
      end

    %{"text" => content} ->
      {:noreply,
       socket
       |> assign(:text_modal_content, content)
       |> assign(:text_modal_label, humanize_key(meta.key))}
  end
end
```

This is the only production code change. The sidebar entry, icons, and click target remain the same — the difference is purely in which modal opens.

### 2. Add test for `.md` text_file opening markdown modal

**File:** `test/destila_web/live/file_metadata_sidebar_live_test.exs`

Add a helper to create a session with a `.md` text_file export and a test that verifies the markdown modal opens:

```elixir
defp create_session_with_md_text_file_export do
  path = Path.join(System.tmp_dir!(), "destila_test_#{System.unique_integer([:positive])}.md")
  File.write!(path, "# Heading\n\nSome **bold** text")
  on_exit(fn -> File.rm(path) end)

  {:ok, ws} =
    Destila.Workflows.insert_workflow_session(%{
      title: "Test Session",
      workflow_type: :brainstorm_idea,
      project_id: nil,
      done_at: DateTime.utc_now(),
      current_phase: 4,
      total_phases: 4
    })

  {:ok, _} =
    Destila.Workflows.upsert_metadata(
      ws.id,
      "phase_4",
      "plan_doc",
      %{"text_file" => path},
      exported: true
    )

  {ws, path}
end
```

Tests to add in a new `describe "text_file with .md extension"` block:

1. **Opens markdown modal instead of text modal** — click the `open_text_modal` button, assert `#markdown-modal` is present and `#text-modal` is not
2. **Regular .txt text_file still opens text modal** — verify existing behavior is preserved (already covered by existing tests, but good to have explicit)

### 3. Update feature file

**File:** `features/exported_metadata.feature`

Add a scenario:

```gherkin
  Scenario: Text file with .md extension uses markdown viewer
    Given I am on a session detail page
    And the session has exported metadata of type "text_file" with a ".md" file extension
    When I click the view button
    Then the markdown modal should open instead of the plain text modal
```

## Files to modify

| File | Change |
|------|--------|
| `lib/destila_web/live/workflow_runner_live.ex` | Add `.md` extension check in `open_text_modal` handler |
| `test/destila_web/live/file_metadata_sidebar_live_test.exs` | Add test for `.md` text_file opening markdown modal |
| `features/exported_metadata.feature` | Add scenario for `.md` extension behavior |

## Design decisions

1. **Detection at modal-open time, not at sidebar render time** — The sidebar entry stays the same for all `text_file` entries regardless of extension. The extension check happens when the user clicks "view", which keeps the sidebar rendering simple and avoids needing to read file metadata just to render the list.

2. **`Path.extname/1` for extension check** — Using Elixir's standard library for reliable extension extraction rather than string matching.

3. **Reuses existing markdown modal** — No new components or modals needed. The `.md` text_file path assigns to the same `@markdown_modal_content` / `@markdown_modal_label` assigns that `markdown` and `markdown_file` types use.
