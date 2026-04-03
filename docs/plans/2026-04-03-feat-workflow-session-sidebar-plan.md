---
title: "feat: Collapsible right sidebar for workflow session details"
type: feat
date: 2026-04-03
---

# feat: Collapsible right sidebar for workflow session details

## Overview

Add a collapsible right sidebar to `WorkflowRunnerLive` that shows session info, project info, exported metadata (grouped by phase), and AI sessions with token usage. The sidebar appears only on active sessions (not the type selection view or pre-session Phase 1), is open by default, and persists its collapsed/expanded state in localStorage via a colocated JS hook.

## Solution

### Architecture

The sidebar is rendered inline within the `render(%{view: :running})` function of `WorkflowRunnerLive`. It sits beside the phase content area in a flex row. The layout changes from the current single-column phase content to a `flex` row containing the phase content (flex-1) and the sidebar.

**Key design decisions:**

1. **No new LiveComponent** — The sidebar is a private function component defined in `WorkflowRunnerLive`. It receives assigns directly from the parent. This avoids the overhead of a LiveComponent lifecycle for what is a pure rendering concern.

2. **Data loading** — Sidebar data (metadata records, AI sessions, phase executions) is loaded in `mount_session/2` and refreshed on PubSub events. The existing `:metadata_updated` handler already refreshes metadata; we add a new `list_metadata_records/1` query that returns the raw `SessionMetadata` structs (grouped by `phase_name`) instead of the flat key→value map used by phases.

3. **Collapsed state via colocated JS hook** — A `.SidebarToggle` colocated hook reads/writes `localStorage["sidebar_collapsed"]` and toggles a `data-sidebar-state` attribute on the outer sidebar wrapper. The hook element has `phx-update="ignore"` so LiveView doesn't clobber the DOM state managed by JS.

   **Critical: `phx-update="ignore"` scope.** The hook container with `phx-update="ignore"` wraps ONLY the toggle button — NOT the sidebar content. The sidebar content div is a sibling that LiveView CAN update (for PubSub-driven metadata refreshes). CSS uses the data attribute on the hook element combined with a general-sibling selector (`~`) to control sidebar visibility.

4. **Token extraction** — A helper function parses `raw_response` maps on AI messages, extracting `usage.input_tokens` and `usage.output_tokens` (or string-keyed equivalents). Returns `nil` gracefully when data is absent.

5. **AI session link** — Each AI session card includes a link that navigates to the workflow session page. Since conversations are viewed within the workflow runner, the link points to `/sessions/:id` (the current page). In the future this could deep-link to a specific AI session view.

### Layout structure

```
┌──────────────────────────────────────────────────┐
│ Header (unchanged)                               │
├──────────────────────────────┬───────────────────┤
│ Phase content (flex-1)       │ Sidebar (w-80)    │
│                              │ ┌───────────────┐ │
│                              │ │ Session Info   │ │
│                              │ │ Project Info   │ │
│                              │ │ Exported Meta  │ │
│                              │ │ AI Sessions    │ │
│                              │ └───────────────┘ │
├──────────────────────────────┴───────────────────┤
│ Done banner (unchanged)                          │
└──────────────────────────────────────────────────┘
```

When collapsed, the sidebar width transitions to 0 and the toggle button remains visible at the right edge.

### Hook + LiveView update strategy

```
<div class="sidebar-wrapper relative flex">
  <%!-- Hook container: phx-update="ignore" — only manages toggle state --%>
  <div id="session-sidebar-toggle" phx-hook=".SidebarToggle" phx-update="ignore"
       data-sidebar-state="open">
    <button data-toggle-sidebar ...>toggle</button>
  </div>

  <%!-- Content: NO phx-update="ignore" — LiveView CAN patch this --%>
  <div id="session-sidebar-content" class="sidebar-panel ...">
    ...sidebar sections...
  </div>
</div>
```

CSS uses `[data-sidebar-state="collapsed"] ~ .sidebar-panel` to hide the content panel when collapsed. This lets the hook manage toggle state in isolation while LiveView patches sidebar data on PubSub events.

## Files to Modify

1. **`lib/destila_web/live/workflow_runner_live.ex`** — Add sidebar rendering, new assigns for sidebar data, update layout structure, add helper functions
2. **`lib/destila/workflows.ex`** — Add `list_metadata_records/1` query returning structs grouped by phase_name
3. **`lib/destila/ai.ex`** — Add `list_ai_sessions_for_workflow/1` query with preloaded messages; add `extract_token_usage/1` and `aggregate_token_usage/1` helpers
4. **`lib/destila/executions.ex`** — (already has `list_phase_executions/1` — no changes needed)
5. **`assets/css/app.css`** — Add sidebar transition CSS rules
6. **`features/workflow_session_sidebar.feature`** — Already created (verify matches prompt spec)
7. **`test/destila_web/live/workflow_session_sidebar_test.exs`** — New test file

## Implementation Steps

### Step 1: Add data query functions

**1a. `lib/destila/workflows.ex`** — Add a function to list metadata records grouped by phase:

```elixir
@doc """
Returns all SessionMetadata records for a workflow session,
grouped by phase_name as a map: %{phase_name => [%SessionMetadata{}, ...]}.
"""
def list_metadata_records(workflow_session_id) do
  from(m in SessionMetadata,
    where: m.workflow_session_id == ^workflow_session_id,
    order_by: [m.phase_name, m.key]
  )
  |> Repo.all()
  |> Enum.group_by(& &1.phase_name)
end
```

**1b. `lib/destila/ai.ex`** — Add function to list all AI sessions for a workflow with message preloading:

```elixir
def list_ai_sessions_for_workflow(workflow_session_id) do
  Repo.all(
    from(s in Session,
      where: s.workflow_session_id == ^workflow_session_id,
      order_by: s.inserted_at,
      preload: :messages
    )
  )
end
```

**1c. `lib/destila/ai.ex`** — Add token usage extraction helper:

```elixir
@doc """
Extracts token usage from a message's raw_response map.
Returns %{input: integer, output: integer} or nil if not available.
"""
def extract_token_usage(%Message{raw_response: raw}) when is_map(raw) do
  usage = raw["usage"] || raw[:usage]

  if is_map(usage) do
    input = usage["input_tokens"] || usage[:input_tokens]
    output = usage["output_tokens"] || usage[:output_tokens]

    if input || output do
      %{input: input, output: output}
    end
  end
end

def extract_token_usage(_), do: nil
```

And a function to aggregate token usage across all messages in an AI session:

```elixir
@doc """
Aggregates total token usage across all messages in an AI session.
Returns %{input: integer, output: integer} or nil if no usage data found.
"""
def aggregate_token_usage(messages) when is_list(messages) do
  messages
  |> Enum.map(&extract_token_usage/1)
  |> Enum.reject(&is_nil/1)
  |> case do
    [] ->
      nil

    usages ->
      %{
        input: usages |> Enum.map(& &1.input) |> Enum.reject(&is_nil/1) |> Enum.sum(),
        output: usages |> Enum.map(& &1.output) |> Enum.reject(&is_nil/1) |> Enum.sum()
      }
  end
end
```

### Step 2: Load sidebar data in WorkflowRunnerLive

In `mount_session/2`, add new assigns after the existing ones:

```elixir
# Sidebar data
metadata_records = Workflows.list_metadata_records(id)
ai_sessions = Destila.AI.list_ai_sessions_for_workflow(id)
phase_executions = Destila.Executions.list_phase_executions(id)

# Add to assigns:
|> assign(:sidebar_metadata, metadata_records)
|> assign(:sidebar_ai_sessions, ai_sessions)
|> assign(:sidebar_phase_executions, phase_executions)
```

In `mount_workflow/2` and `mount_type_selection/1`, assign empty defaults so the assigns exist even when the sidebar is not rendered:

```elixir
|> assign(:sidebar_metadata, %{})
|> assign(:sidebar_ai_sessions, [])
|> assign(:sidebar_phase_executions, [])
```

### Step 3: Refresh sidebar data on PubSub events

**3a. Update `:metadata_updated` handler** — Already refreshes `@metadata` (flat map for phases). Add sidebar metadata refresh:

```elixir
def handle_info({:metadata_updated, ws_id}, socket) do
  if socket.assigns[:workflow_session] && ws_id == socket.assigns.workflow_session.id do
    {:noreply,
     socket
     |> assign(:metadata, Workflows.get_metadata(ws_id))
     |> assign(:sidebar_metadata, Workflows.list_metadata_records(ws_id))}
  else
    {:noreply, socket}
  end
end
```

**3b. Update `:workflow_session_updated` handler** — Refresh AI sessions and phase executions when the session updates (phase transitions create new AI sessions/executions):

```elixir
# Inside the existing handler, after existing assigns:
|> assign(:sidebar_ai_sessions, Destila.AI.list_ai_sessions_for_workflow(updated_ws.id))
|> assign(:sidebar_phase_executions, Destila.Executions.list_phase_executions(updated_ws.id))
```

### Step 4: Add the colocated JS hook for sidebar toggle

The hook is placed inside the `render_sidebar/1` function component. **Critical:** The hook element wraps ONLY the toggle button (with `phx-update="ignore"`). The sidebar content panel is a sibling element that LiveView CAN patch.

```heex
<script :type={Phoenix.LiveView.ColocatedHook} name=".SidebarToggle">
  export default {
    mounted() {
      const stored = localStorage.getItem("sidebar_collapsed")
      if (stored === "true") {
        this.el.dataset.sidebarState = "collapsed"
      }

      this.el.addEventListener("click", (e) => {
        const btn = e.target.closest("[data-toggle-sidebar]")
        if (!btn) return

        const current = this.el.dataset.sidebarState
        const next = current === "collapsed" ? "open" : "collapsed"
        this.el.dataset.sidebarState = next
        localStorage.setItem("sidebar_collapsed", next === "collapsed")
      })
    }
  }
</script>
```

### Step 5: Update the render layout

Change the `render(%{view: :running})` template structure. The current layout is:

```
flex flex-col h-screen
  ├─ Header (border-b)
  ├─ Phase content (flex-1 min-h-0)
  └─ Done banner
```

New layout — wrap the phase content + sidebar in a flex row:

```heex
<div class="flex flex-col h-screen">
  <%!-- Header (unchanged) --%>
  ...

  <%!-- Main content area: phase + sidebar --%>
  <div class="flex flex-1 min-h-0">
    <%!-- Phase content --%>
    <div class="flex-1 min-w-0">
      {render_phase(assigns)}
    </div>

    <%!-- Sidebar — only when we have a persisted workflow session --%>
    <%= if @workflow_session do %>
      {render_sidebar(assigns)}
    <% end %>
  </div>

  <%!-- Done banner (unchanged) --%>
  ...
</div>
```

The sidebar only renders when `@workflow_session` is set. This is `nil` in two cases:
- **Type selection** (`/workflows`) — `@view == :selecting_type`, so this render branch isn't reached
- **Pre-session Phase 1** (`/workflows/:workflow_type`) — `@view == :running` but `@workflow_session == nil`

Both cases correctly skip the sidebar.

### Step 6: Implement the sidebar rendering function

Define `render_sidebar/1` as a private function in `WorkflowRunnerLive`:

```elixir
defp render_sidebar(assigns) do
  ~H"""
  <div class="sidebar-wrapper relative flex" id="session-sidebar">
    <%!-- Hook container: manages toggle state only. phx-update="ignore" prevents
         LiveView from resetting the data-sidebar-state attribute on patches. --%>
    <div
      id="session-sidebar-toggle"
      phx-hook=".SidebarToggle"
      phx-update="ignore"
      data-sidebar-state="open"
      class="relative z-10"
    >
      <button
        data-toggle-sidebar
        class={[
          "absolute -left-3 top-4 flex items-center justify-center",
          "w-6 h-6 rounded-full bg-base-200 border border-base-300",
          "hover:bg-base-300 transition-colors shadow-sm cursor-pointer"
        ]}
        id="sidebar-toggle-btn"
      >
        <span class="toggle-icon-open">
          <.icon name="hero-chevron-right-micro" class="size-3.5" />
        </span>
        <span class="toggle-icon-collapsed">
          <.icon name="hero-chevron-left-micro" class="size-3.5" />
        </span>
      </button>
    </div>

    <%!-- Sidebar content panel: LiveView CAN patch this (no phx-update="ignore").
         CSS hides/shows it based on the hook's data-sidebar-state attribute. --%>
    <div id="session-sidebar-content" class="sidebar-panel border-l border-base-300 bg-base-100 overflow-y-auto">
      <div class="p-4 space-y-6">
        <%!-- Session Info --%>
        <section id="sidebar-session-info">
          <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">
            Session Info
          </h3>
          <dl class="space-y-2 text-sm">
            <div class="flex justify-between">
              <dt class="text-base-content/50">Created</dt>
              <dd>{format_datetime(@workflow_session.inserted_at)}</dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/50">Updated</dt>
              <dd>{format_datetime(@workflow_session.updated_at)}</dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/50">Duration</dt>
              <dd>{format_duration(@workflow_session.inserted_at)}</dd>
            </div>
            <%= if @workflow_session.done_at do %>
              <div class="flex justify-between" id="sidebar-completed-date">
                <dt class="text-base-content/50">Completed</dt>
                <dd class="text-success">{format_datetime(@workflow_session.done_at)}</dd>
              </div>
            <% else %>
              <div class="flex justify-between">
                <dt class="text-base-content/50">Status</dt>
                <dd>In progress</dd>
              </div>
            <% end %>
          </dl>
        </section>

        <%!-- Project Info --%>
        <%= if @project do %>
          <section id="sidebar-project-info">
            <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">
              Project
            </h3>
            <div class="text-sm space-y-1">
              <p class="font-medium" id="sidebar-project-name">{@project.name}</p>
              <p
                :if={@project.git_repo_url}
                class="text-xs text-base-content/40 truncate"
                id="sidebar-project-repo"
              >
                {@project.git_repo_url}
              </p>
            </div>
          </section>
        <% end %>

        <%!-- Exported Metadata --%>
        <section id="sidebar-metadata">
          <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">
            Exported Metadata
          </h3>
          <%= if @sidebar_metadata == %{} do %>
            <p class="text-sm text-base-content/30 italic" id="sidebar-metadata-empty">
              No metadata exported yet
            </p>
          <% else %>
            <div class="space-y-4">
              <%= for {phase_name, records} <- @sidebar_metadata do %>
                <div id={"sidebar-metadata-#{phase_name}"}>
                  <h4 class="text-xs font-medium text-base-content/60 mb-2 capitalize">
                    {phase_name}
                  </h4>
                  <dl class="space-y-1.5">
                    <%= for record <- records do %>
                      <div class="flex justify-between gap-2 text-xs">
                        <dt class="text-base-content/50 truncate">{record.key}</dt>
                        <dd class="text-right font-mono truncate max-w-[120px]">
                          {format_metadata_value(record.value)}
                        </dd>
                      </div>
                    <% end %>
                  </dl>
                </div>
              <% end %>
            </div>
          <% end %>
        </section>

        <%!-- AI Sessions --%>
        <section id="sidebar-ai-sessions">
          <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">
            AI Sessions
          </h3>
          <%= if @sidebar_ai_sessions == [] do %>
            <p class="text-sm text-base-content/30 italic" id="sidebar-ai-sessions-empty">
              No AI sessions yet
            </p>
          <% else %>
            <div class="space-y-3">
              <%= for ai_session <- @sidebar_ai_sessions do %>
                <div
                  class="p-2.5 rounded-lg bg-base-200/50 text-xs space-y-1.5"
                  id={"sidebar-ai-session-#{ai_session.id}"}
                >
                  <div class="flex items-center justify-between">
                    <span class="font-medium">
                      {ai_session_phase_label(ai_session, @workflow_session)}
                    </span>
                    <span class={[
                      "px-1.5 py-0.5 rounded text-[10px] font-medium",
                      ai_session_status_class(ai_session, @sidebar_phase_executions)
                    ]}>
                      {ai_session_status(ai_session, @sidebar_phase_executions)}
                    </span>
                  </div>
                  <%!-- Token usage --%>
                  <.sidebar_token_usage ai_session={ai_session} />
                  <%!-- View conversation link --%>
                  <.link
                    navigate={~p"/sessions/#{@workflow_session.id}"}
                    class="text-primary/70 hover:text-primary transition-colors text-[11px]"
                  >
                    View conversation
                  </.link>
                </div>
              <% end %>
            </div>
          <% end %>
        </section>
      </div>
    </div>
  </div>

  <script :type={Phoenix.LiveView.ColocatedHook} name=".SidebarToggle">
    export default {
      mounted() {
        const stored = localStorage.getItem("sidebar_collapsed")
        if (stored === "true") {
          this.el.dataset.sidebarState = "collapsed"
        }

        this.el.addEventListener("click", (e) => {
          const btn = e.target.closest("[data-toggle-sidebar]")
          if (!btn) return

          const current = this.el.dataset.sidebarState
          const next = current === "collapsed" ? "open" : "collapsed"
          this.el.dataset.sidebarState = next
          localStorage.setItem("sidebar_collapsed", next === "collapsed")
        })
      }
    }
  </script>
  """
end
```

### Step 7: Implement helper functions

Add private helpers to `WorkflowRunnerLive`:

```elixir
defp format_datetime(nil), do: "—"

defp format_datetime(dt) do
  Calendar.strftime(dt, "%b %d, %Y %H:%M")
end

defp format_duration(start_time) do
  diff = DateTime.diff(DateTime.utc_now(), start_time, :second)

  cond do
    diff < 60 -> "#{diff}s"
    diff < 3600 -> "#{div(diff, 60)}m"
    true -> "#{div(diff, 3600)}h #{div(rem(diff, 3600), 60)}m"
  end
end

defp format_metadata_value(%{"text" => text}) when is_binary(text) do
  if String.length(text) > 40, do: String.slice(text, 0, 40) <> "…", else: text
end

defp format_metadata_value(value) when is_map(value), do: Jason.encode!(value)
defp format_metadata_value(value), do: inspect(value)

defp ai_session_phase_label(ai_session, workflow_session) do
  # Determine which phase this AI session is for from its messages' phase field
  phase_number =
    case ai_session.messages do
      [first | _] -> first.phase
      [] -> nil
    end

  if phase_number do
    name = Workflows.phase_name(workflow_session.workflow_type, phase_number)
    name || "Phase #{phase_number}"
  else
    "AI Session"
  end
end

defp ai_session_status(ai_session, phase_executions) do
  phase_number =
    case ai_session.messages do
      [first | _] -> first.phase
      [] -> nil
    end

  pe = Enum.find(phase_executions, &(&1.phase_number == phase_number))

  cond do
    pe && pe.status == "completed" -> "Completed"
    pe && pe.status == "processing" -> "Processing"
    pe && pe.status == "awaiting_input" -> "Waiting"
    pe && pe.status == "awaiting_confirmation" -> "Review"
    pe -> String.capitalize(pe.status)
    true -> "Unknown"
  end
end

defp ai_session_status_class(ai_session, phase_executions) do
  status = ai_session_status(ai_session, phase_executions)

  case status do
    "Completed" -> "bg-success/20 text-success"
    "Processing" -> "bg-primary/20 text-primary"
    "Waiting" -> "bg-warning/20 text-warning"
    "Review" -> "bg-info/20 text-info"
    _ -> "bg-base-300 text-base-content/60"
  end
end
```

Add a function component for token usage display:

```elixir
defp sidebar_token_usage(assigns) do
  usage = Destila.AI.aggregate_token_usage(assigns.ai_session.messages)
  assigns = assign(assigns, :usage, usage)

  ~H"""
  <div :if={@usage} class="flex items-center gap-3 text-base-content/40">
    <span>
      <.icon name="hero-arrow-down-tray-micro" class="size-3 inline" />
      {format_tokens(@usage.input)} in
    </span>
    <span>
      <.icon name="hero-arrow-up-tray-micro" class="size-3 inline" />
      {format_tokens(@usage.output)} out
    </span>
  </div>
  """
end

defp format_tokens(nil), do: "—"
defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
defp format_tokens(n), do: "#{n}"
```

### Step 8: Add CSS for sidebar transitions

In `assets/css/app.css`, add rules for the sidebar toggle animation. The CSS uses a general-sibling combinator to control the sidebar panel based on the hook element's data attribute:

```css
/* Right sidebar toggle transitions */
.sidebar-wrapper .sidebar-panel {
  width: 20rem; /* w-80 */
  min-width: 20rem;
  transition: width 0.3s ease, min-width 0.3s ease, opacity 0.2s ease;
  opacity: 1;
}

[data-sidebar-state="collapsed"] ~ .sidebar-panel {
  width: 0;
  min-width: 0;
  opacity: 0;
  overflow: hidden;
}

/* Toggle icon rotation */
.sidebar-wrapper .toggle-icon-open { display: inline; }
.sidebar-wrapper .toggle-icon-collapsed { display: none; }
[data-sidebar-state="collapsed"] .toggle-icon-open { display: none; }
[data-sidebar-state="collapsed"] .toggle-icon-collapsed { display: inline; }
```

### Step 9: Verify Gherkin feature file

The feature file `features/workflow_session_sidebar.feature` already exists with the correct scenarios from the prompt. Verify it matches the spec and all scenarios are present.

### Step 10: Create tests

Create `test/destila_web/live/workflow_session_sidebar_test.exs`:

```elixir
defmodule DestilaWeb.WorkflowSessionSidebarTest do
  @moduledoc """
  LiveView tests for the workflow session sidebar.
  Feature: features/workflow_session_sidebar.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "workflow_session_sidebar"

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

  # --- Helpers ---

  defp create_project do
    {:ok, project} =
      Destila.Projects.create_project(%{
        name: "Test Project",
        git_repo_url: "https://github.com/test/repo"
      })

    project
  end

  defp create_session(attrs \\ %{}) do
    defaults = %{
      title: "Test Session",
      workflow_type: :brainstorm_idea,
      current_phase: 3,
      total_phases: 6,
      phase_status: :awaiting_input
    }

    {:ok, ws} = Destila.Workflows.create_workflow_session(Map.merge(defaults, attrs))
    ws
  end

  defp create_ai_session_with_messages(ws) do
    {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

    {:ok, _} =
      Destila.AI.create_message(ai_session.id, %{
        role: :system,
        content: "Let's work on this.",
        phase: 3,
        raw_response: %{
          "text" => "Let's work on this.",
          "usage" => %{"input_tokens" => 1500, "output_tokens" => 300}
        }
      })

    {:ok, _} =
      Destila.AI.create_message(ai_session.id, %{
        role: :user,
        content: "Fix the login bug",
        phase: 3
      })

    ai_session
  end

  # --- Tests ---

  @tag feature: @feature, scenario: "Sidebar is visible by default on an active session"
  test "sidebar is visible on session detail page", %{conn: conn} do
    ws = create_session()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#session-sidebar")
    assert has_element?(view, "#session-sidebar-content")
    assert has_element?(view, "#sidebar-session-info")
  end

  @tag feature: @feature, scenario: "Sidebar is not shown on workflow type selection"
  test "sidebar is not rendered on type selection page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workflows")

    refute has_element?(view, "#session-sidebar")
  end

  @tag feature: @feature, scenario: "Collapse and expand the sidebar"
  test "toggle button exists with data-toggle-sidebar attribute", %{conn: conn} do
    ws = create_session()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#sidebar-toggle-btn[data-toggle-sidebar]")
    assert has_element?(view, "#session-sidebar-toggle[phx-hook='.SidebarToggle']")
  end

  @tag feature: @feature, scenario: "Sidebar shows session info"
  test "sidebar shows session creation date and duration", %{conn: conn} do
    ws = create_session()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#sidebar-session-info")
    # Verify session info section has the expected structure (dt/dd pairs)
    assert has_element?(view, "#sidebar-session-info dt")
    assert has_element?(view, "#sidebar-session-info dd")
  end

  @tag feature: @feature, scenario: "Sidebar shows done status for completed session"
  test "sidebar shows completion date when session is done", %{conn: conn} do
    ws = create_session(%{done_at: DateTime.utc_now()})

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#sidebar-completed-date")
  end

  @tag feature: @feature, scenario: "Sidebar shows project info"
  test "sidebar shows project name and repository URL", %{conn: conn} do
    project = create_project()
    ws = create_session(%{project_id: project.id})

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#sidebar-project-info")
    assert has_element?(view, "#sidebar-project-name")
    assert has_element?(view, "#sidebar-project-repo")
  end

  @tag feature: @feature, scenario: "Sidebar shows exported metadata grouped by phase"
  test "sidebar shows metadata grouped by phase name", %{conn: conn} do
    ws = create_session()

    Destila.Workflows.upsert_metadata(ws.id, "wizard", "idea", %{"text" => "My idea"})
    Destila.Workflows.upsert_metadata(ws.id, "wizard", "prompt", %{"text" => "A prompt"})
    Destila.Workflows.upsert_metadata(ws.id, "setup", "repo_cloned", %{"text" => "true"})

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#sidebar-metadata-wizard")
    assert has_element?(view, "#sidebar-metadata-setup")
    refute has_element?(view, "#sidebar-metadata-empty")
  end

  @tag feature: @feature, scenario: "Sidebar updates when new metadata is exported"
  test "sidebar updates in real-time when new metadata is broadcast", %{conn: conn} do
    ws = create_session()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    # Initially no metadata
    assert has_element?(view, "#sidebar-metadata-empty")

    # Add metadata (this triggers PubSub broadcast)
    Destila.Workflows.upsert_metadata(ws.id, "wizard", "idea", %{"text" => "New idea"})

    # Wait for the PubSub message to arrive and be processed
    _ = render(view)

    assert has_element?(view, "#sidebar-metadata-wizard")
    refute has_element?(view, "#sidebar-metadata-empty")
  end

  @tag feature: @feature, scenario: "Sidebar shows AI sessions"
  test "sidebar shows AI sessions with status", %{conn: conn} do
    ws = create_session()
    ai_session = create_ai_session_with_messages(ws)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#sidebar-ai-sessions")
    assert has_element?(view, "#sidebar-ai-session-#{ai_session.id}")
    refute has_element?(view, "#sidebar-ai-sessions-empty")
  end

  @tag feature: @feature, scenario: "Sidebar shows AI sessions"
  test "sidebar shows empty state when no AI sessions", %{conn: conn} do
    ws = create_session()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#sidebar-ai-sessions-empty")
  end

  @tag feature: @feature, scenario: "Sidebar shows exported metadata grouped by phase"
  test "sidebar shows empty state when no metadata", %{conn: conn} do
    ws = create_session()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#sidebar-metadata-empty")
  end
end
```

### Step 11: Run `mix precommit`

Verify compilation, formatting, and all tests pass.

## Edge Cases

### No workflow session (pre-session Phase 1)

When navigating to `/workflows/:workflow_type`, `@workflow_session` is nil. The sidebar is not rendered. This is already handled by the `<%= if @workflow_session do %>` guard in the template.

### No metadata yet

The sidebar shows "No metadata exported yet" when `@sidebar_metadata == %{}`.

### No AI sessions yet

The sidebar shows "No AI sessions yet" when `@sidebar_ai_sessions == []`.

### Token data missing from raw_response

`extract_token_usage/1` returns `nil` when `raw_response` is nil, not a map, or doesn't contain `usage` data. The `sidebar_token_usage` component only renders when usage is present (`:if={@usage}`).

### Metadata value is a complex map

`format_metadata_value/1` handles the common `%{"text" => "..."}` pattern and falls back to `Jason.encode!` for arbitrary maps.

### Multiple AI sessions for same phase

This can happen with the `:new` session strategy. Each AI session is listed separately. The phase label is derived from the first message's `phase` field.

### Sidebar state persistence across navigation

The colocated JS hook reads from `localStorage` on `mounted()`, so navigating away and back preserves the collapsed state. Since the hook element has `phx-update="ignore"`, LiveView won't reset the data attribute during patches.

### Long metadata values or keys

Values and keys use `truncate` CSS class to prevent layout breakage. Values are capped at 120px max width.

### `phx-update="ignore"` vs sidebar content updates

The `phx-update="ignore"` is scoped to only the toggle button container (which holds the `data-sidebar-state` attribute). The sidebar content panel is a separate sibling element that LiveView patches normally. CSS uses the `[data-sidebar-state="collapsed"] ~ .sidebar-panel` sibling selector to toggle visibility based on the hook's state. This ensures:
- Toggle state survives LiveView patches
- Sidebar content (metadata, AI sessions) updates in real-time via PubSub

## Corrections from deepening review

1. **`phx-update="ignore"` scope issue** — The original plan wrapped the ENTIRE sidebar (toggle + content) in `phx-update="ignore"`. This would prevent LiveView from updating sidebar content when PubSub events fire (metadata updates, session changes). Fixed by scoping `phx-update="ignore"` to only the toggle button container, leaving sidebar content patchable by LiveView. CSS sibling selectors bridge the two elements.

2. **Missing "View conversation" link** — The prompt requires a clickable link on each AI session to view the full conversation. Added a `<.link navigate={...}>View conversation</.link>` to each AI session card.

3. **Missing concrete test code** — Replaced bullet-point test strategy with complete ExUnit test implementations including `@tag` annotations, fixture helpers, and assertions using DOM element IDs.

4. **DOM IDs for test targeting** — Added unique DOM IDs to all sidebar sections and key elements (`#sidebar-session-info`, `#sidebar-project-info`, `#sidebar-metadata-wizard`, `#sidebar-ai-session-#{id}`, etc.) to enable reliable LiveViewTest assertions using `has_element?/2`.

5. **Empty default assigns** — Ensured `mount_workflow/2` and `mount_type_selection/1` assign empty defaults for all sidebar assigns (`sidebar_metadata`, `sidebar_ai_sessions`, `sidebar_phase_executions`) even though the sidebar isn't rendered in those cases, to prevent potential undefined assign errors.

## Verification

1. `mix precommit` passes
2. Navigate to `/sessions/:id` — sidebar is visible and open
3. Navigate to `/workflows` — no sidebar
4. Navigate to `/workflows/:workflow_type` — no sidebar (pre-session Phase 1)
5. Click toggle — sidebar collapses with smooth animation
6. Refresh page — sidebar state persists (collapsed stays collapsed)
7. Check Session Info section shows correct dates and duration
8. Check Project Info shows name and repo URL
9. Trigger metadata export (via running a workflow) — sidebar updates in real-time
10. Check AI Sessions section shows status, token usage, and conversation link
11. Check empty states when no metadata or AI sessions exist
