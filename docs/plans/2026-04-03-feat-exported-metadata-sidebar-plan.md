---
title: "feat: Exported metadata flag and sidebar"
type: feat
date: 2026-04-03
---

# feat: Exported metadata flag and sidebar

## Overview

Add an `exported` boolean flag to `workflow_session_metadata` entries. When other workflow sessions, the execution engine, or the workflow runner query metadata for a given session, only entries marked as `exported: true` are returned. Metadata is private by default.

Build a collapsible sidebar in `WorkflowRunnerLive` that displays exported metadata for the current session during execution. The sidebar updates in real-time via PubSub and persists its collapse state in localStorage.

## Solution

### Architecture

1. **Database** — Add `exported` boolean column (default `false`) to `workflow_session_metadata`. The existing unique constraint on `[:workflow_session_id, :phase_name, :key]` is unchanged.

2. **Context API** — Extend `upsert_metadata/4` to accept an optional 5th keyword argument (`exported: true`). Add `get_exported_metadata/1` that returns full `SessionMetadata` structs where `exported == true`. The `on_conflict` clause replaces `exported` alongside `value` and `updated_at`.

3. **Workflow** — Mark the `prompt_generated` metadata in `brainstorm_idea_workflow.ex` as `exported: true`. All other existing metadata remains private.

4. **LiveView** — Add `exported_metadata` assign (list of `SessionMetadata` structs) fetched on mount and refreshed on `:metadata_updated`. Render a collapsible sidebar alongside the phase content.

5. **JS Hook** — Colocated `.MetadataSidebar` hook manages collapse/expand state via localStorage. The hook does NOT use `phx-update="ignore"` — it manages CSS classes (`hidden`) and a `data-collapsed` attribute. The hook's `updated()` callback reapplies collapse state after each LiveView DOM patch.

### Key design decisions

1. **Separate assign** — `exported_metadata` is a list of `SessionMetadata` structs, distinct from the existing `metadata` assign (flattened key-value map used by phase components). This avoids coupling the two concerns.

2. **Full structs, not a flat map** — The sidebar needs `phase_name`, `key`, and `value` to render expandable cards. Returning structs from `get_exported_metadata/1` provides this without a second query.

3. **No streams for sidebar** — The exported metadata list will be small (typically 1-5 items). A regular assign with full re-render on update is simpler and sufficient.

4. **localStorage for persistence** — The colocated `.MetadataSidebar` hook reads/writes `metadata-sidebar-collapsed` in localStorage. Open by default (when no key exists).

5. **No `phx-update="ignore"`** — The sidebar content must be updated by LiveView when `exported_metadata` changes (new entries arriving via PubSub). Using `phx-update="ignore"` would prevent LiveView from patching the content. Instead, the hook manages only CSS visibility classes and reapplies them in `updated()` after each LiveView patch. This lets LiveView freely update the metadata entries while the hook preserves the collapse/expand state.

6. **`ImplementGeneralPromptWorkflow` not affected** — This workflow does NOT call `save_phase_metadata` or write `prompt_generated` metadata during execution. It receives an existing prompt via the wizard and stores it under the `"wizard"` phase_name with key `"prompt"`. Only `BrainstormIdeaWorkflow` generates prompts in Phase 6.

## Files to Modify

1. **`priv/repo/migrations/<timestamp>_add_exported_to_session_metadata.exs`** — New migration
2. **`lib/destila/workflows/session_metadata.ex`** — Add `exported` field to schema and changeset
3. **`lib/destila/workflows.ex`** — Extend `upsert_metadata`, add `get_exported_metadata/1`
4. **`lib/destila/workflows/brainstorm_idea_workflow.ex`** — Pass `exported: true` for `prompt_generated`
5. **`lib/destila_web/live/workflow_runner_live.ex`** — Add `exported_metadata` assign, sidebar template, `.MetadataSidebar` hook
6. **`features/exported_metadata.feature`** — New feature file with Gherkin scenarios
7. **`test/destila/workflows_metadata_test.exs`** — Add tests for exported flag and `get_exported_metadata/1`
8. **`test/destila_web/live/brainstorm_idea_workflow_live_test.exs`** — Add sidebar tests

## Implementation Steps

### Step 1: Database migration

Create a new migration to add the `exported` column:

```elixir
defmodule Destila.Repo.Migrations.AddExportedToSessionMetadata do
  use Ecto.Migration

  def change do
    alter table(:workflow_session_metadata) do
      add :exported, :boolean, default: false, null: false
    end
  end
end
```

No index needed on `exported` — queries will always filter by `workflow_session_id` first (which is already indexed), and the number of metadata rows per session is small.

### Step 2: Update SessionMetadata schema

In `lib/destila/workflows/session_metadata.ex`, add the `exported` field:

```elixir
schema "workflow_session_metadata" do
  field(:phase_name, :string)
  field(:key, :string)
  field(:value, :map)
  field(:exported, :boolean, default: false)

  belongs_to(:workflow_session, Destila.Workflows.Session)

  timestamps(type: :utc_datetime)
end

def changeset(metadata, attrs) do
  metadata
  |> cast(attrs, [:workflow_session_id, :phase_name, :key, :value, :exported])
  |> validate_required([:workflow_session_id, :phase_name, :key, :value])
end
```

The `exported` field is not in `validate_required` — it defaults to `false` at both the schema and database level.

### Step 3: Extend upsert_metadata and add get_exported_metadata

In `lib/destila/workflows.ex`:

**3a. Extend `upsert_metadata` to accept an optional keyword argument:**

```elixir
def upsert_metadata(workflow_session_id, phase_name, key, value, opts \\ []) do
  exported = Keyword.get(opts, :exported, false)
  now = DateTime.utc_now() |> DateTime.truncate(:second)

  %SessionMetadata{}
  |> SessionMetadata.changeset(%{
    workflow_session_id: workflow_session_id,
    phase_name: phase_name,
    key: key,
    value: value,
    exported: exported
  })
  |> Repo.insert(
    on_conflict: {:replace, [:value, :exported, :updated_at]},
    conflict_target: [:workflow_session_id, :phase_name, :key],
    set: [updated_at: now]
  )
  |> case do
    {:ok, metadata} ->
      Destila.PubSubHelper.broadcast_event(:metadata_updated, workflow_session_id)
      {:ok, metadata}

    {:error, changeset} ->
      {:error, changeset}
  end
end
```

All existing call sites pass 4 arguments, so `opts` defaults to `[]` and `exported` defaults to `false`. No existing callers need changes.

**Important:** The `on_conflict` clause now includes `:exported` in the `{:replace, [...]}` list. This ensures that when a metadata entry is upserted, the `exported` flag is also updated. Without this, re-upserting a key that was previously non-exported would fail to mark it as exported.

**3b. Add `get_exported_metadata/1`:**

```elixir
def get_exported_metadata(workflow_session_id) do
  from(m in SessionMetadata,
    where: m.workflow_session_id == ^workflow_session_id and m.exported == true,
    order_by: [m.phase_name, m.key]
  )
  |> Repo.all()
end
```

Returns full `SessionMetadata` structs (not the flattened map), ordered by phase_name then key for consistent display.

### Step 4: Mark prompt_generated as exported

In `lib/destila/workflows/brainstorm_idea_workflow.ex`, modify `save_phase_metadata/3`:

```elixir
defp save_phase_metadata(ws, phase_number, response_text) do
  case Enum.at(phases(), phase_number - 1) do
    {_mod, opts} ->
      if Keyword.get(opts, :message_type) == :generated_prompt do
        phase_name = phase_name(phase_number)

        Destila.Workflows.upsert_metadata(
          ws.id,
          phase_name,
          "prompt_generated",
          %{"text" => String.trim(response_text)},
          exported: true
        )
      end

    _ ->
      :ok
  end
end
```

Only this single call site gets the `exported: true` flag. All other existing metadata (wizard inputs, setup steps, title generation, repo_sync, worktree, source_session) remain private by default.

### Step 5: Add exported_metadata assign to WorkflowRunnerLive

In `lib/destila_web/live/workflow_runner_live.ex`:

**5a. Initialize assign in all mount paths:**

In `mount_type_selection/1` (after line 43) and `mount_workflow/2` (after line 64):
```elixir
|> assign(:exported_metadata, [])
```

In `mount_session/2` (after the existing `assign(:metadata, ...)` on line 102):
```elixir
|> assign(:exported_metadata, Workflows.get_exported_metadata(workflow_session.id))
```

**5b. Refresh on `:metadata_updated`:**

Update the existing `handle_info({:metadata_updated, ws_id}, socket)` handler (line 313) to also refresh exported metadata:

```elixir
def handle_info({:metadata_updated, ws_id}, socket) do
  if socket.assigns[:workflow_session] && ws_id == socket.assigns.workflow_session.id do
    {:noreply,
     socket
     |> assign(:metadata, Workflows.get_metadata(ws_id))
     |> assign(:exported_metadata, Workflows.get_exported_metadata(ws_id))}
  else
    {:noreply, socket}
  end
end
```

### Step 6: Add sidebar to WorkflowRunnerLive template

**6a. Modify the phase content container to use flex row layout:**

In `workflow_runner_live.ex`, find the current phase content area (line 531-534):

```heex
<%!-- Phase content — full remaining height, phase manages its own layout --%>
<div class="flex-1 min-h-0">
  {render_phase(assigns)}
</div>
```

Replace with a flex row that holds both the phase content and the sidebar:

```heex
<%!-- Phase content + sidebar — full remaining height --%>
<div class="flex flex-row flex-1 min-h-0">
  <%!-- Phase content — takes remaining space --%>
  <div class="flex-1 min-h-0 overflow-hidden">
    {render_phase(assigns)}
  </div>

  <%!-- Exported metadata sidebar --%>
  <%= if @workflow_session do %>
    <div
      id="metadata-sidebar"
      phx-hook=".MetadataSidebar"
      class="flex flex-col border-l border-base-300 shrink-0"
    >
      <%!-- Toggle button — always visible --%>
      <button
        id="metadata-sidebar-toggle"
        class="p-2 border-b border-base-300 bg-base-100 hover:bg-base-200 transition-colors flex items-center justify-center"
        data-action="toggle-sidebar"
      >
        <.icon name="hero-chevron-right-micro" class="size-4 text-base-content/50 sidebar-icon-collapsed hidden" />
        <.icon name="hero-chevron-left-micro" class="size-4 text-base-content/50 sidebar-icon-expanded" />
      </button>

      <%!-- Sidebar content — toggled by hook --%>
      <div id="metadata-sidebar-content" class="w-80 overflow-y-auto flex-1 bg-base-100">
        <div class="p-4">
          <h3 class="text-sm font-semibold text-base-content/70 mb-3">Exported Metadata</h3>

          <%= if @exported_metadata == [] do %>
            <p class="text-xs text-base-content/40 italic">
              No metadata has been exported yet.
            </p>
          <% else %>
            <div class="space-y-2">
              <details
                :for={meta <- @exported_metadata}
                id={"metadata-entry-#{meta.id}"}
                class="group"
                open
              >
                <summary class="flex items-center gap-2 cursor-pointer p-2 rounded-lg hover:bg-base-200 transition-colors text-sm">
                  <.icon name="hero-chevron-right-micro" class="size-3 text-base-content/40 group-open:rotate-90 transition-transform" />
                  <span class="font-medium text-base-content/70">{meta.phase_name}</span>
                  <span class="text-base-content/40">&middot;</span>
                  <span class="text-base-content/50">{meta.key}</span>
                </summary>
                <div class="pl-7 pr-2 pb-2">
                  <div class="text-xs text-base-content/60 bg-base-200/50 rounded-lg p-3 max-h-64 overflow-y-auto whitespace-pre-wrap break-words">
                    {format_metadata_value(meta.value)}
                  </div>
                </div>
              </details>
            </div>
          <% end %>
        </div>
      </div>
    </div>
  <% end %>
</div>
```

**Key layout notes:**
- The phase content div gets `overflow-hidden` to prevent it from expanding beyond its flex allocation when content is large.
- The sidebar div gets `shrink-0` to prevent flexbox from compressing it.
- When collapsed, only the toggle button column (with `border-l`) is visible — a thin strip at the right edge.
- The `w-80` (20rem) on the content div provides a reasonable width for reading metadata values.

**6b. Add the `format_metadata_value/1` helper:**

Add this private function to `workflow_runner_live.ex` (after `maybe_put/3` at line 582):

```elixir
defp format_metadata_value(%{"text" => text}) when is_binary(text), do: text
defp format_metadata_value(value) when is_map(value), do: Jason.encode!(value, pretty: true)
defp format_metadata_value(value), do: inspect(value)
```

**6c. Add the colocated `.MetadataSidebar` JS hook:**

Place the `<script>` tag inside the `render(%{view: :running})` function's `~H` sigil, at the top level — after the closing `</div>` of the flex column and before `</Layouts.app>`. Colocated hooks are automatically extracted by the Phoenix build pipeline and do not render visible content.

**Complete hook code** (includes both `mounted()` and `updated()` — both are critical):

```heex
<script :type={Phoenix.LiveView.ColocatedHook} name=".MetadataSidebar">
  export default {
    mounted() {
      const collapsed = localStorage.getItem("metadata-sidebar-collapsed") === "true"
      this.applyState(collapsed)

      this.el.querySelector("[data-action=toggle-sidebar]")
        .addEventListener("click", () => {
          const isCollapsed = this.el.dataset.collapsed === "true"
          this.applyState(!isCollapsed)
          localStorage.setItem("metadata-sidebar-collapsed", String(!isCollapsed))
        })
    },
    updated() {
      const collapsed = localStorage.getItem("metadata-sidebar-collapsed") === "true"
      this.applyState(collapsed)
    },
    applyState(collapsed) {
      const content = this.el.querySelector("#metadata-sidebar-content")
      const iconCollapsed = this.el.querySelector(".sidebar-icon-collapsed")
      const iconExpanded = this.el.querySelector(".sidebar-icon-expanded")

      if (!content || !iconCollapsed || !iconExpanded) return

      this.el.dataset.collapsed = collapsed

      if (collapsed) {
        content.classList.add("hidden")
        iconCollapsed.classList.remove("hidden")
        iconExpanded.classList.add("hidden")
      } else {
        content.classList.remove("hidden")
        iconCollapsed.classList.add("hidden")
        iconExpanded.classList.remove("hidden")
      }
    }
  }
</script>
```

**Why `updated()` is critical:** The hook manages CSS classes (`hidden`) on elements inside the sidebar. When LiveView patches the DOM (e.g., new exported metadata arrives via PubSub), it re-renders the server-side HTML which does NOT include the `hidden` class. This means every LiveView patch would reset the sidebar to its server-rendered state (expanded). The `updated()` callback fires after every LiveView patch and reapplies the collapse state from localStorage, preserving the user's preference.

**Why null-guard in `applyState`:** The `content`, `iconCollapsed`, and `iconExpanded` elements might not exist during the brief moment between mount paths or if the sidebar is conditionally hidden. The null guard prevents runtime errors.

**Why `String(!isCollapsed)` in localStorage:** `localStorage.setItem` converts values to strings, but `!isCollapsed` is a boolean. Using `String()` makes the intent explicit and avoids the `"false"` vs `false` ambiguity.

### Step 7: Create Gherkin feature file

Create `features/exported_metadata.feature` with the scenarios from the user prompt:

```gherkin
Feature: Exported Metadata
  Workflow sessions store metadata during execution. Individual metadata entries
  can be flagged as "exported", making them available to other workflow sessions
  during their creation. A collapsible sidebar in the workflow runner displays
  the exported metadata for the current session during execution.

  Background:
    Given I am logged in

  Scenario: Metadata is private by default
    Given a workflow session has metadata entries
    Then metadata entries should not be exported by default

  Scenario: Generated prompt is marked as exported
    Given a "Brainstorm Idea" workflow completes Phase 6 - Prompt Generation
    Then the generated prompt metadata should be marked as exported

  Scenario: Only exported metadata is returned when querying for external use
    Given a workflow session has both exported and non-exported metadata
    When another workflow session queries the metadata
    Then only exported entries should be returned

  Scenario: Sidebar displays exported metadata during workflow execution
    Given I am on a session detail page
    And the session has exported metadata entries
    Then I should see a sidebar showing the exported metadata
    And each entry should display its phase name and key

  Scenario: Sidebar is empty when no metadata is exported
    Given I am on a session detail page
    And the session has no exported metadata entries
    Then the sidebar should indicate no exported metadata is available

  Scenario: Sidebar updates in real-time as metadata is exported
    Given I am on a session detail page
    And the session is actively processing
    When a phase marks new metadata as exported
    Then the sidebar should update to show the new entry

  Scenario: Sidebar is open by default
    Given I am on a session detail page for the first time
    Then the sidebar should be open

  Scenario: Collapse and expand sidebar
    Given I am on a session detail page
    And the sidebar is open
    When I collapse the sidebar
    Then the sidebar should be hidden
    When I expand the sidebar
    Then the sidebar should be visible again

  Scenario: Sidebar collapse state persists across page loads
    Given I am on a session detail page
    And I collapse the sidebar
    When I navigate away and return to the session detail page
    Then the sidebar should still be collapsed
```

### Step 8: Add tests

**8a. Context tests in `test/destila/workflows_metadata_test.exs`:**

Add new describe blocks:

```elixir
describe "upsert_metadata/5 with exported flag" do
  test "defaults exported to false" do
    ws = create_session()
    {:ok, metadata} = Workflows.upsert_metadata(ws.id, "setup", "title_gen", %{"status" => "done"})
    assert metadata.exported == false
  end

  test "sets exported to true when passed" do
    ws = create_session()
    {:ok, metadata} = Workflows.upsert_metadata(ws.id, "phase6", "prompt_generated", %{"text" => "Do X"}, exported: true)
    assert metadata.exported == true
  end

  test "upsert replaces exported flag on conflict" do
    ws = create_session()
    {:ok, _} = Workflows.upsert_metadata(ws.id, "phase6", "prompt_generated", %{"text" => "v1"})
    {:ok, updated} = Workflows.upsert_metadata(ws.id, "phase6", "prompt_generated", %{"text" => "v2"}, exported: true)
    assert updated.exported == true
    assert updated.value == %{"text" => "v2"}
  end
end

describe "get_exported_metadata/1" do
  test "returns empty list when no metadata exists" do
    ws = create_session()
    assert Workflows.get_exported_metadata(ws.id) == []
  end

  test "returns empty list when no metadata is exported" do
    ws = create_session()
    {:ok, _} = Workflows.upsert_metadata(ws.id, "setup", "title_gen", %{"status" => "done"})
    {:ok, _} = Workflows.upsert_metadata(ws.id, "wizard", "idea", %{"text" => "my idea"})
    assert Workflows.get_exported_metadata(ws.id) == []
  end

  test "returns only exported entries as full structs" do
    ws = create_session()
    {:ok, _} = Workflows.upsert_metadata(ws.id, "setup", "title_gen", %{"status" => "done"})
    {:ok, _} = Workflows.upsert_metadata(ws.id, "phase6", "prompt_generated", %{"text" => "prompt"}, exported: true)

    exported = Workflows.get_exported_metadata(ws.id)
    assert length(exported) == 1

    [entry] = exported
    assert %Destila.Workflows.SessionMetadata{} = entry
    assert entry.phase_name == "phase6"
    assert entry.key == "prompt_generated"
    assert entry.value == %{"text" => "prompt"}
    assert entry.exported == true
  end

  test "returns entries ordered by phase_name then key" do
    ws = create_session()
    {:ok, _} = Workflows.upsert_metadata(ws.id, "z_phase", "alpha", %{"v" => "1"}, exported: true)
    {:ok, _} = Workflows.upsert_metadata(ws.id, "a_phase", "beta", %{"v" => "2"}, exported: true)
    {:ok, _} = Workflows.upsert_metadata(ws.id, "a_phase", "alpha", %{"v" => "3"}, exported: true)

    exported = Workflows.get_exported_metadata(ws.id)
    assert length(exported) == 3
    assert Enum.map(exported, & &1.phase_name) == ["a_phase", "a_phase", "z_phase"]
    assert Enum.map(exported, & &1.key) == ["alpha", "beta", "alpha"]
  end
end
```

**8b. LiveView sidebar tests in `test/destila_web/live/brainstorm_idea_workflow_live_test.exs`:**

Add a new describe block for sidebar behavior:

```elixir
describe "exported metadata sidebar" do
  @tag feature: "exported_metadata", scenario: "Sidebar displays exported metadata during workflow execution"
  test "shows sidebar with exported metadata entries", %{conn: conn} do
    ws = create_session_in_phase(3)
    Destila.Workflows.upsert_metadata(ws.id, "Prompt Generation", "prompt_generated", %{"text" => "Do the thing"}, exported: true)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#metadata-sidebar")
    assert has_element?(view, "#metadata-sidebar-content")
    # Entry should show phase name and key
    assert render(view) =~ "Prompt Generation"
    assert render(view) =~ "prompt_generated"
  end

  @tag feature: "exported_metadata", scenario: "Sidebar is empty when no metadata is exported"
  test "shows empty state when no metadata is exported", %{conn: conn} do
    ws = create_session_in_phase(3)
    # Insert non-exported metadata
    Destila.Workflows.upsert_metadata(ws.id, "setup", "title_gen", %{"status" => "done"})

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#metadata-sidebar")
    assert render(view) =~ "No metadata has been exported yet"
  end

  @tag feature: "exported_metadata", scenario: "Sidebar updates in real-time as metadata is exported"
  test "updates sidebar when new exported metadata arrives via PubSub", %{conn: conn} do
    ws = create_session_in_phase(3)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    # Initially empty
    assert render(view) =~ "No metadata has been exported yet"

    # Simulate metadata being exported (this triggers PubSub broadcast)
    Destila.Workflows.upsert_metadata(ws.id, "Prompt Generation", "prompt_generated", %{"text" => "New prompt"}, exported: true)

    # Wait for PubSub update to propagate
    _ = render(view)

    refute render(view) =~ "No metadata has been exported yet"
    assert render(view) =~ "Prompt Generation"
    assert render(view) =~ "prompt_generated"
  end

  @tag feature: "exported_metadata", scenario: "Sidebar is open by default"
  test "sidebar is visible by default", %{conn: conn} do
    ws = create_session_in_phase(3)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#metadata-sidebar")
    assert has_element?(view, "#metadata-sidebar-content")
  end
end
```

Note: Collapse/expand and localStorage persistence tests require browser-level testing (e.g., Wallaby) because they depend on JavaScript execution. The LiveView tests verify server-rendered state.

### Step 9: Run `mix precommit`

Verify compilation, formatting, and all tests pass.

## Edge Cases

### Upsert with changing exported flag

If a metadata entry is first inserted without `exported: true` and later upserted with `exported: true`, the `on_conflict` clause replaces the `exported` column. This is the expected behavior — a workflow can upgrade a private entry to exported.

### Multiple exported entries

The sidebar handles multiple exported entries naturally. Each renders as an expandable `<details>` card. The list is ordered by phase_name then key for consistency.

### Empty metadata value

The `format_metadata_value/1` helper handles different value shapes: maps with a `"text"` key extract the text, other maps are JSON-encoded, and fallback uses `inspect/2`.

### LiveView patches and hook state

When LiveView patches the sidebar content (e.g., new metadata arrives), the hook's `updated()` callback reapplies the collapse state from localStorage. This prevents the sidebar from unexpectedly expanding/collapsing during re-renders.

### Non-session views (type selection, pre-session)

The sidebar only renders when `@workflow_session` is present (`<%= if @workflow_session do %>`). On the type selection page and pre-session Phase 1, `@workflow_session` is `nil`, so no sidebar appears.

## Corrections from deepening review

The following issues were identified and corrected during the plan deepening pass:

1. **Architecture section contradicted Step 6** — The original Architecture point 5 mentioned `phx-update="ignore"` but Step 6 correctly rejected this approach. The sidebar content must be updated by LiveView when `exported_metadata` changes, so `phx-update="ignore"` cannot be used. Fixed to describe the actual approach: CSS class management with `updated()` callback.

2. **Step 6 showed rejected approach before final approach** — The original Step 6 included a first draft with `phx-update="ignore"`, followed by a "Wait — problem" narrative, then the corrected version. This was confusing for an implementation plan. Cleaned up to show only the final approach.

3. **JS hook code was incomplete** — The `updated()` callback was mentioned as a separate afterthought but not included in the main hook code block. This callback is critical — without it, every LiveView DOM patch would reset the sidebar to its expanded state by removing the `hidden` class. Integrated `updated()` into the complete hook code.

4. **Missing null-guard in `applyState`** — Added null-guard for `content`, `iconCollapsed`, and `iconExpanded` elements to prevent runtime errors during transient DOM states.

5. **Missing layout overflow handling** — Added `overflow-hidden` to the phase content div and `shrink-0` to the sidebar div. Without these, the phase content could expand beyond its flex allocation and the sidebar could be compressed by flexbox.

6. **Exact line references added** — Added specific line numbers for where to insert the `exported_metadata` assign in each mount function and the `format_metadata_value/1` helper.

7. **`ImplementGeneralPromptWorkflow` scope clarification** — Confirmed this workflow does NOT need changes: it does not call `save_phase_metadata` or write `prompt_generated` metadata. It stores the user's input prompt under `"wizard"/"prompt"`, which remains private.

## Verification

1. `mix precommit` passes
2. Manual test: Complete a Brainstorm Idea workflow through Phase 6 — sidebar shows the generated prompt
3. Manual test: Check that setup/wizard metadata does NOT appear in the sidebar
4. Manual test: Collapse the sidebar — navigate away — return — sidebar remains collapsed
5. Manual test: Expand the sidebar — navigate away — return — sidebar remains expanded
6. Manual test: While on a session page, watch the sidebar update in real-time when Phase 6 generates a prompt
