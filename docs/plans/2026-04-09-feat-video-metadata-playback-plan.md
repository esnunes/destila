---
title: "feat: Video metadata playback"
type: feat
date: 2026-04-09
---

# feat: Video metadata playback

## Overview

When a workflow exports metadata with type `video_file`, the system currently renders the raw filesystem path as plain text — both in the inline chat card and in the sidebar. This feature adds actual video playback: a streaming endpoint serves the MP4 from disk, an inline `video_card` component replaces the plain card in chat, and the sidebar gets a play button that opens a modal video player.

## Current state

- **Metadata types** (`lib/destila/workflows.ex:12`): `@valid_metadata_types ~w(text text_file markdown video_file)` — `video_file` is already a valid type.
- **Export extraction** (`lib/destila/ai/response_processor.ex:152-168`): `do_extract_export_actions/1` returns `%{key, value, type}` maps. The `type` field is already propagated.
- **Chat branching** (`lib/destila_web/components/chat_components.ex:289-303`): `chat_message/1` iterates exports. If `type == "markdown"` → `markdown_card`, else → `plain_card`. A `video_file` export currently falls into `plain_card`, showing the raw path.
- **Sidebar** (`lib/destila_web/live/workflow_runner_live.ex:611-631`): Renders all exported metadata in `<details>` blocks with `metadata_value_block/1`. For `video_file`, `format_metadata_value/1` (line 766) returns the raw path string.
- **Router** (`lib/destila_web/router.ex`): Only LiveView routes and a session controller. No file-serving endpoints.
- **Endpoint** (`lib/destila_web/endpoint.ex`): `Plug.Static` serves from `priv/static`. No custom media serving.
- **SessionMetadata schema** (`lib/destila/workflows/session_metadata.ex`): Has `id` (binary_id), `key`, `value` (map). The `value` map for video_file is `%{"video_file" => "/absolute/path.mp4"}`.
- **Workflows context** (`lib/destila/workflows.ex:294-300`): `get_all_metadata/1` returns all `SessionMetadata` records. No function to fetch a single record by ID.
- **Feature file** (`features/exported_metadata.feature`): 83 lines covering sidebar behavior and inline chat cards for markdown/text types. No video scenarios.

## Key design decisions

### 1. Streaming controller with range request support

A new `DestilaWeb.MediaController` serves MP4 files at `GET /media/:id`. It looks up the `SessionMetadata` record by ID, extracts the path from `value["video_file"]`, and streams the file. Using the metadata ID in the URL keeps filesystem paths out of the browser and naturally scopes access to existing records.

**No `.mp4` extension in the URL.** The `:browser` pipeline's `:accepts` plug only allows `"html"` format. A `.mp4` extension would trigger Phoenix's format negotiation, rejecting the request. Instead, the controller sets `Content-Type: video/mp4` explicitly, which is sufficient for browsers to treat the response as video. The frontend references `/media/<uuid>` without any extension.

Range requests (`Range` header) are required for browser seeking. The controller parses the `Range` header, responds with `206 Partial Content` for range requests and `200 OK` for full requests, setting `Content-Type`, `Content-Length`, `Accept-Ranges`, and `Content-Range` headers appropriately. The file is sent via `Plug.Conn.send_file/5` which supports offset and length parameters.

### 2. New `video_card` component in chat_components.ex

Follows the same visual frame as `markdown_card` and `plain_card`: D-avatar on the left, bordered card with primary/20 border, header bar with humanized key name. The body contains an HTML5 `<video>` element with `controls` and no autoplay. Source URL is `/media/<metadata_id>`.

The `chat_message/1` template adds a third branch: if `export.type == "video_file"`, render `video_card`. This requires the export map to carry the metadata ID, which is looked up from the sidebar's `@exported_metadata` list.

### 3. Export maps need a `metadata_id` field for video_file types

The inline `video_card` needs the metadata record's ID to construct the `/media/:id` URL. Currently, exports extracted from `raw_response` only have `%{key, value, type}` — no database ID. Two approaches:

**Chosen approach:** Pass `exported_metadata` (the list of `SessionMetadata` structs already loaded in the LiveView) into `chat_message/1` as an attr. When rendering a `video_file` export, look up the matching metadata record by key to get its ID. This avoids changing the response processor or adding a DB query per message render. The lookup is O(n) on a small list (typically <10 exported entries).

### 4. Sidebar play button opens a modal

For `video_file` entries in the sidebar, replace the `<details>` expand with a play button. Clicking it opens a modal overlay containing a larger `<video>` player. The modal uses a LiveView component with `phx-click` to open/close, storing the active video metadata ID in an assign (`:video_modal_meta_id`). The modal renders a backdrop + centered video player with a close button.

### 5. Route placement and auth

The `/media/:id` route goes inside the authenticated scope (`pipe_through [:browser, :require_auth]`). This ensures only logged-in users can access video files, consistent with the rest of the app.

## Changes

### Step 1: Add `get_metadata!` to the Workflows context

**File:** `lib/destila/workflows.ex`

Add a function to fetch a single `SessionMetadata` by ID, used by the media controller:

```elixir
def get_metadata!(id), do: Repo.get!(SessionMetadata, id)
```

Add after the existing `get_all_metadata/1` function (line 300).

### Step 2: Create MediaController

**File:** `lib/destila_web/controllers/media_controller.ex` (new)

Create a controller with a single `show` action. Uses `Plug.Conn.send_file/5` which supports offset and length parameters for both full and range requests without manual chunking.

```elixir
defmodule DestilaWeb.MediaController do
  use DestilaWeb, :controller

  alias Destila.Workflows

  def show(conn, %{"id" => id}) do
    metadata = Workflows.get_metadata!(id)
    path = metadata.value["video_file"]
    %{size: size} = File.stat!(path)

    conn = put_resp_header(conn, "accept-ranges", "bytes")

    case get_req_header(conn, "range") do
      ["bytes=" <> range_spec] ->
        {start_pos, end_pos} = parse_range(range_spec, size)
        length = end_pos - start_pos + 1

        conn
        |> put_resp_header("content-type", "video/mp4")
        |> put_resp_header("content-range", "bytes #{start_pos}-#{end_pos}/#{size}")
        |> send_file(206, path, start_pos, length)

      _ ->
        conn
        |> put_resp_header("content-type", "video/mp4")
        |> send_file(200, path, 0, size)
    end
  end

  defp parse_range(range_spec, size) do
    case String.split(range_spec, "-", parts: 2) do
      [start_str, ""] ->
        start_pos = String.to_integer(start_str)
        {start_pos, size - 1}

      [start_str, end_str] ->
        {String.to_integer(start_str), String.to_integer(end_str)}
    end
  end
end
```

### Step 3: Add route

**File:** `lib/destila_web/router.ex`

Add inside the authenticated scope, right after `live "/sessions/archived"` (line 44) and before `live "/sessions/:id"` (line 45):

```elixir
get "/media/:id", MediaController, :show
```

No `.mp4` extension — the scope alias resolves this to `DestilaWeb.MediaController`. Placement before the `:id` catch-all LiveView route avoids path conflicts.

### Step 4: Add `video_card` component

**File:** `lib/destila_web/components/chat_components.ex`

Add a new `video_card` component after `plain_card` (after line 619). It follows the same visual pattern:

Attrs:
- `id` (string, required)
- `key` (string, required) — metadata key for the header
- `metadata_id` (string, required) — the SessionMetadata record ID for the `/media/:id` URL

Template structure (same card frame as `markdown_card`):
- D-avatar circle on the left
- Bordered card (`rounded-2xl border-2 border-primary/20 bg-base-200 overflow-hidden`)
- Header bar with humanized key name (same style: `bg-primary/10 border-b border-primary/20`)
- Body: `<video>` element with `controls`, `preload="metadata"`, class styling for rounded corners and full width
- `<source>` pointing to `/media/{@metadata_id}` with `type="video/mp4"`

```elixir
attr :id, :string, required: true
attr :key, :string, required: true
attr :metadata_id, :string, required: true

defp video_card(assigns) do
  ~H"""
  <div class="flex gap-3 mb-4">
    <div class="w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold flex-shrink-0 bg-primary text-primary-content">
      D
    </div>
    <div class="max-w-[80%]">
      <div id={@id} class="rounded-2xl border-2 border-primary/20 bg-base-200 overflow-hidden">
        <div class="px-4 py-2 bg-primary/10 border-b border-primary/20 flex items-center gap-2">
          <.icon name="hero-film-micro" class="size-4 text-primary" />
          <span class="text-xs font-medium text-primary uppercase tracking-wide">
            {humanize_key(@key)}
          </span>
        </div>
        <div class="p-3">
          <video controls preload="metadata" class="w-full rounded-lg">
            <source src={"/media/#{@metadata_id}"} type="video/mp4" />
          </video>
        </div>
      </div>
    </div>
  </div>
  """
end
```

No JS hook needed — the native `<video>` element with `controls` handles playback.

### Step 5: Update `chat_message/1` to branch on `video_file`

**File:** `lib/destila_web/components/chat_components.ex`

Add `exported_metadata` as an attr to `chat_message`:

```elixir
attr :exported_metadata, :list, default: []
```

Update the export rendering loop (lines 289-303) to add a `video_file` branch. When `export.type == "video_file"`, find the matching metadata record from `@exported_metadata` by key and render `video_card`:

```elixir
<%= for {export, idx} <- Enum.with_index(@exports) do %>
  <%= cond do %>
    <% (export.type || "text") == "markdown" -> %>
      <.markdown_card
        id={"export-md-#{@message.id}-#{idx}"}
        key={export.key}
        content={export.value}
      />
    <% (export.type || "text") == "video_file" -> %>
      <% meta = Enum.find(@exported_metadata, &(&1.key == export.key)) %>
      <%= if meta do %>
        <.video_card
          id={"export-video-#{@message.id}-#{idx}"}
          key={export.key}
          metadata_id={meta.id}
        />
      <% end %>
    <% true -> %>
      <.plain_card
        id={"export-plain-#{@message.id}-#{idx}"}
        key={export.key}
        content={export.value}
      />
  <% end %>
<% end %>
```

### Step 6: Pass `exported_metadata` through to `chat_message`

Three files need edits to thread `exported_metadata` from the LiveView down to `chat_message`:

**File:** `lib/destila_web/components/chat_components.ex`

1. Add attr declaration to `chat_phase/1` (after `attr :phase_status, :atom, default: nil` at line 38):

   ```elixir
   attr :exported_metadata, :list, default: []
   ```

2. Pass it through at both `<.chat_message>` call sites inside `chat_phase/1`:
   - **Line 69-74** (inside the multi-phase `<details>` branch): add `exported_metadata={@exported_metadata}` to the existing attrs
   - **Line 91-96** (inside the single-phase `<div>` branch): same addition

**File:** `lib/destila_web/live/workflow_runner_live.ex`

3. In `do_render_phase/2` (lines 708-718), add `exported_metadata={@exported_metadata}` to the `<.chat_phase>` call. The LiveView already has `@exported_metadata` in assigns from `assign_metadata/2` (line 735).

### Step 7: Update sidebar for video_file entries

**File:** `lib/destila_web/live/workflow_runner_live.ex`

In the exported metadata sidebar section (lines 611-631), modify the `:for` loop to handle video entries differently. For `video_file` type metadata, render a play button instead of a `<details>` expand. Clicking it sets `:video_modal_meta_id` assign.

Replace the `<details :for={meta <- @exported_metadata} ...>` block (lines 612-630) with a `for` comprehension that conditionally renders video entries differently:

```elixir
<div class="space-y-1.5">
  <%= for meta <- @exported_metadata do %>
    <%= if Map.has_key?(meta.value, "video_file") do %>
      <div
        id={"metadata-entry-#{meta.id}"}
        class="flex items-center gap-2 px-3 py-2 rounded-lg border border-base-300/60 hover:bg-base-200/50 transition-colors duration-150"
      >
        <.icon name="hero-film-micro" class="size-3 text-base-content/30 shrink-0" />
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
    <% else %>
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

### Step 8: Add video modal

**File:** `lib/destila_web/live/workflow_runner_live.ex`

**Assign:** Add `|> assign(:video_modal_meta_id, nil)` to the assign chain in `mount_session/2` (after line 65, the `assign(:question_answers, %{})` line).

**Event handlers:** Add near the other `handle_event` functions:

```elixir
def handle_event("open_video_modal", %{"id" => id}, socket) do
  {:noreply, assign(socket, :video_modal_meta_id, id)}
end

def handle_event("close_video_modal", _params, socket) do
  {:noreply, assign(socket, :video_modal_meta_id, nil)}
end
```

**Modal template:** Insert right before `</Layouts.app>` at the end of `render/1`. The modal renders when `@video_modal_meta_id` is not nil. Specifically, insert before the closing on line 649 (`</div>` that closes the outer flex container), placing it as a sibling of the main layout content:

```heex
<div
  :if={@video_modal_meta_id}
  id="video-modal"
  class="fixed inset-0 z-50 flex items-center justify-center"
>
  <div
    class="absolute inset-0 bg-black/70 backdrop-blur-sm"
    phx-click="close_video_modal"
  />
  <div class="relative z-10 w-full max-w-3xl mx-4">
    <button
      phx-click="close_video_modal"
      class="absolute -top-10 right-0 text-white/70 hover:text-white transition-colors"
      aria-label="Close video"
    >
      <.icon name="hero-x-mark" class="size-6" />
    </button>
    <video controls autoplay class="w-full rounded-xl shadow-2xl">
      <source src={"/media/#{@video_modal_meta_id}"} type="video/mp4" />
    </video>
  </div>
</div>
```

**Click handling:** The `phx-click="close_video_modal"` is on the **backdrop div only**, not the outer container. This prevents clicks on the video player from closing the modal. The close button provides an explicit dismissal mechanism.

### Step 9: Update Gherkin feature files

**File:** `features/exported_metadata.feature`

Append video scenarios after the existing inline chat message section (after line 83):

```gherkin
  Scenario: Video metadata appears as inline chat message
    Given I am on a session detail page
    And the AI exports metadata with type "video_file"
    Then a chat message should appear with the video card component
    And the card header should show the humanized metadata key
    And the card should display a video player with click-to-play controls
    And the video should not autoplay

  Scenario: Video metadata sidebar entry has play button
    Given I am on a session detail page
    And the session has exported metadata of type "video_file"
    Then the sidebar entry should display a play button instead of a text preview
    When I click the play button
    Then a modal overlay should open with a larger video player
```

**File:** `features/video_metadata_viewing.feature` (new)

```gherkin
Feature: Video Metadata Viewing
  When a workflow exports video_file-type metadata, it is displayed inline
  in the chat using a video card component. Users can play the video directly
  in the chat or open a larger modal from the metadata sidebar. Videos are
  served via a streaming endpoint that reads MP4 files from the local filesystem.

  Background:
    Given I am logged in
    And a session has exported video_file metadata

  Scenario: Video card displays with click-to-play controls
    Then the video card should display an HTML5 video player
    And the player should show standard playback controls
    And the video should not be playing

  Scenario: Play video inline
    When I click the play button on the video card
    Then the video should start playing

  Scenario: Open video in modal from sidebar
    When I click the play button on the sidebar video entry
    Then a modal overlay should appear
    And the modal should contain a larger video player
    And the modal video should have playback controls

  Scenario: Close video modal
    Given the video modal is open
    When I close the modal
    Then the modal should disappear
    And the inline video card should still be visible

  Scenario: Video file is streamed from disk
    Given the exported video_file path points to a valid MP4 file
    Then the video player source should load via the streaming endpoint
    And the video should be playable
```

### Step 10: Write tests

**File:** `test/destila_web/controllers/media_controller_test.exs` (new)

Follow the `ConnCase` pattern. Setup creates a temp file and a `SessionMetadata` record:

```elixir
defmodule DestilaWeb.MediaControllerTest do
  use DestilaWeb.ConnCase, async: false

  @feature "video_metadata_viewing"

  setup %{conn: conn} do
    # Create a temp MP4 file with test bytes
    path = Path.join(System.tmp_dir!(), "test_video_#{System.unique_integer([:positive])}.mp4")
    File.write!(path, :crypto.strong_rand_bytes(1024))
    on_exit(fn -> File.rm(path) end)

    # Create workflow session + metadata
    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test", workflow_type: :brainstorm_idea,
        project_id: nil, current_phase: 1, total_phases: 1
      })

    {:ok, meta} =
      Destila.Workflows.upsert_metadata(ws.id, "phase_1", "demo_video",
        %{"video_file" => path}, exported: true)

    conn = post(conn, "/login", %{"email" => "test@example.com"})
    {:ok, conn: conn, meta: meta, video_path: path}
  end
end
```

Test cases:
- `@tag feature: @feature, scenario: "Video file is streamed from disk"` — Full request returns 200 with `content-type: video/mp4` and `accept-ranges: bytes` headers, body matches file content
- `@tag feature: @feature, scenario: "Video file is streamed from disk"` — Range request (`Range: bytes=0-99`) returns 206 with `content-range` header and 100-byte body
- `@tag feature: @feature, scenario: "Video file is streamed from disk"` — Open-ended range (`Range: bytes=100-`) returns bytes from offset 100 to EOF
- Auth test — unauthenticated request (fresh `build_conn()` without login) redirects to `/login`

**File:** `test/destila_web/live/video_metadata_viewing_live_test.exs` (new)

Follow the pattern from `markdown_metadata_viewing_live_test.exs`. Setup creates a session with a `video_file` export (the message's `raw_response` includes an MCP tool use with `type: "video_file"`). The metadata value stores a path, but the LiveView test only checks DOM structure — it doesn't need the file to exist since the `<video>` element just references the URL.

```elixir
defmodule DestilaWeb.VideoMetadataViewingLiveTest do
  @moduledoc """
  LiveView tests for Video Metadata Viewing.
  Feature: features/video_metadata_viewing.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "video_metadata_viewing"

  setup %{conn: conn} do
    ClaudeCode.Test.set_mode_to_shared()
    ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
      [ClaudeCode.Test.text("AI response"), ClaudeCode.Test.result("AI response")]
    end)

    conn = post(conn, "/login", %{"email" => "test@example.com"})
    {:ok, conn: conn}
  end

  defp create_session_with_video_export do
    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test Session", workflow_type: :brainstorm_idea,
        project_id: nil, done_at: DateTime.utc_now(),
        current_phase: 4, total_phases: 4
      })

    {:ok, _ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

    {:ok, _} =
      Destila.AI.create_message(ws.id |> Destila.AI.get_ai_session_for_workflow() |> Map.get(:id), %{
        role: :system,
        content: "Here is the video output.",
        raw_response: %{
          "text" => "Here is the video output.",
          "result" => "Here is the video output.",
          "mcp_tool_uses" => [
            %{
              "name" => "mcp__destila__session",
              "input" => %{
                "action" => "export",
                "key" => "demo_video",
                "value" => "/tmp/test.mp4",
                "type" => "video_file"
              }
            }
          ],
          "is_error" => false
        },
        phase: 4,
        workflow_session_id: ws.id
      })

    Destila.Workflows.upsert_metadata(ws.id, "phase_4", "demo_video",
      %{"video_file" => "/tmp/test.mp4"}, exported: true)

    ws
  end
end
```

Test cases:
- `@tag feature: @feature, scenario: "Video card displays with click-to-play controls"` — `has_element?(view, "[id^='export-video-']")` and `has_element?(view, "video")` and `has_element?(view, "source[type='video/mp4']")`
- `@tag feature: @feature, scenario: "Video card displays with click-to-play controls"` — Source URL contains `/media/` prefix: `render(view) =~ "/media/"`
- `@tag feature: @feature, scenario: "Video card displays with click-to-play controls"` — Card header shows humanized key: `render(view) =~ "Demo Video"`
- `@tag feature: @feature, scenario: "Open video in modal from sidebar"` — Sidebar entry has play button: `has_element?(view, "button[phx-click='open_video_modal']")`
- `@tag feature: @feature, scenario: "Open video in modal from sidebar"` — Click play opens modal: after `render_click(element(view, "button[phx-click='open_video_modal']"))`, assert `has_element?(view, "#video-modal")`
- `@tag feature: @feature, scenario: "Close video modal"` — Click close button removes modal: after opening, `render_click(element(view, "#video-modal button[phx-click='close_video_modal']"))`, assert `!has_element?(view, "#video-modal")`

## File summary

| File | Action | Description |
|------|--------|-------------|
| `lib/destila/workflows.ex` | Edit | Add `get_metadata!/1` |
| `lib/destila_web/controllers/media_controller.ex` | New | Streaming endpoint with range support |
| `lib/destila_web/router.ex` | Edit | Add `/media/:id` route |
| `lib/destila_web/components/chat_components.ex` | Edit | Add `video_card`, update `chat_message` branching, add `exported_metadata` attr |
| `lib/destila_web/live/workflow_runner_live.ex` | Edit | Sidebar play button, video modal, pass `exported_metadata` to chat |
| `features/exported_metadata.feature` | Edit | Append video scenarios |
| `features/video_metadata_viewing.feature` | New | Full video viewing feature file |
| `test/destila_web/controllers/media_controller_test.exs` | New | Controller tests (200, 206, auth) |
| `test/destila_web/live/video_metadata_viewing_live_test.exs` | New | LiveView integration tests (card, sidebar, modal) |
