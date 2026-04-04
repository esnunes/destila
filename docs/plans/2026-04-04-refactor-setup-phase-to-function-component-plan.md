---
title: "refactor: Transform SetupPhase from LiveComponent to function component"
type: refactor
date: 2026-04-04
---

# refactor: Transform SetupPhase from LiveComponent to function component

## Overview

Convert `DestilaWeb.Phases.SetupPhase` from a LiveComponent (with `update/2` lifecycle and `handle_event/3`) into a plain Phoenix function component. All state derivation happens at render time. The `retry_setup` event handler moves to `WorkflowRunnerLive`. The `build_steps/2` database query is removed in favor of a static label.

## Current state

- `SetupPhase` uses `DestilaWeb, :live_component` with:
  - `update/2` that builds steps from `workflow_session` and `metadata` assigns
  - `handle_event("retry_setup", ...)` that calls `Destila.Workflows.prepare_workflow_session/1`
  - `render/1` that delegates to a `step_item/1` function component
- `WorkflowRunnerLive.render_phase/1` renders it via `<.live_component module={DestilaWeb.Phases.SetupPhase} ...>`
- `build_steps/2` calls `Destila.Projects.get_project/1` to decide between "Pulling latest changes..." and "Syncing repository..." for the repo sync step label
- The retry button uses `phx-target={@myself}` to route events to the LiveComponent

## Solution

### Architecture

1. **SetupPhase becomes a function component module** — `use DestilaWeb, :html` instead of `:live_component`. Exports a single `setup_phase/1` function component that accepts `workflow_session` and `metadata` as assigns.
2. **State derivation at render time** — `build_steps/2` is called inside the component function body, not in a lifecycle callback. No `update/2` or `handle_event/3`.
3. **`retry_setup` moves to WorkflowRunnerLive** — the parent already owns `workflow_session`, so it can call `Destila.Workflows.prepare_workflow_session/1` directly.
4. **Repo sync label simplified** — always "Syncing repository...", no database query.
5. **Retry button loses `phx-target`** — events bubble to the parent LiveView naturally.

### Key design decisions

1. **Module stays in `lib/destila_web/live/phases/setup_phase.ex`** — the file path doesn't change. The module is still namespaced under `DestilaWeb.Phases.SetupPhase` and keeps all its helper functions (`build_steps`, `get_step_status`, `get_step_error`, `all_completed?`, `has_failure?`). The runner doesn't need to know about setup step internals.

2. **`use DestilaWeb, :html`** — this gives access to `~H`, `Phoenix.Component`, and `CoreComponents` (for `<.icon>`). It's the standard way to define function component modules in this project.

3. **No new assigns needed in WorkflowRunnerLive** — the runner already has `workflow_session` and `metadata` assigns that are passed through to the component call.

## Implementation steps

### Step 1: Convert SetupPhase to a function component

**File: `lib/destila_web/live/phases/setup_phase.ex`**

Replace `use DestilaWeb, :live_component` with `use DestilaWeb, :html`.

Remove `update/2` callback entirely. Remove `handle_event("retry_setup", ...)` callback entirely.

Replace `render/1` with a public function component `setup_phase/1` that:
- Accepts `workflow_session` and `metadata` as required assigns
- Calls `build_steps/2` inline to derive `steps`
- Assigns `steps` into the assigns map for template use

```elixir
defmodule DestilaWeb.Phases.SetupPhase do
  @moduledoc """
  Function component for setup status — displays setup progress (title generation,
  repo sync, worktree creation). Rendered by WorkflowRunnerLive when
  `phase_status` is `:setup`.
  """

  use DestilaWeb, :html

  attr :workflow_session, :map, required: true
  attr :metadata, :map, required: true

  def setup_phase(assigns) do
    ws = assigns.workflow_session
    metadata = assigns.metadata
    steps = build_steps(ws, metadata)

    assigns =
      assigns
      |> assign(:steps, steps)
      |> assign(:all_done, all_completed?(steps))
      |> assign(:has_failure, has_failure?(steps))

    ~H"""
    <div class="overflow-y-auto h-full px-6 py-6">
      <div class="max-w-2xl mx-auto space-y-2">
        <.step_item :for={step <- @steps} step={step} />
      </div>
    </div>
    """
  end

  # ... step_item/1, build_steps/2, helpers unchanged except as noted below
end
```

### Step 2: Remove database query from `build_steps/2`

**File: `lib/destila_web/live/phases/setup_phase.ex`**

In `build_steps/2`, remove the `Destila.Projects.get_project/1` call and the conditional label logic. Always use `"Syncing repository..."` for the repo sync step.

Before:
```elixir
repo_steps =
  if ws.project_id do
    project = Destila.Projects.get_project(ws.project_id)
    repo_label =
      if project && project.local_folder && project.local_folder != "",
        do: "Pulling latest changes...",
        else: "Syncing repository..."
    [%{key: "repo_sync", label: repo_label, ...}, ...]
  else
    []
  end
```

After:
```elixir
repo_steps =
  if ws.project_id do
    [
      %{key: "repo_sync", label: "Syncing repository...",
        status: get_step_status(metadata, "repo_sync"),
        error: get_step_error(metadata, "repo_sync")},
      %{key: "worktree", label: "Creating worktree...",
        status: get_step_status(metadata, "worktree"),
        error: get_step_error(metadata, "worktree")}
    ]
  else
    []
  end
```

### Step 3: Remove `phx-target` from retry button

**File: `lib/destila_web/live/phases/setup_phase.ex`**

In `step_item/1`, remove `@myself` from assigns (it no longer exists) and remove `phx-target={@myself}` from the retry button. The event will bubble up to `WorkflowRunnerLive`.

Before:
```heex
<.step_item :for={step <- @steps} step={step} myself={@myself} />
```
After:
```heex
<.step_item :for={step <- @steps} step={step} />
```

Before:
```heex
<button
  :if={@step.status == "failed"}
  phx-click="retry_setup"
  phx-target={@myself}
  class="btn btn-xs btn-outline btn-error"
>
```
After:
```heex
<button
  :if={@step.status == "failed"}
  phx-click="retry_setup"
  class="btn btn-xs btn-outline btn-error"
>
```

### Step 4: Add `retry_setup` handler to WorkflowRunnerLive

**File: `lib/destila_web/live/workflow_runner_live.ex`**

Add a new `handle_event/3` clause for `"retry_setup"`:

```elixir
def handle_event("retry_setup", _params, socket) do
  Destila.Workflows.prepare_workflow_session(socket.assigns.workflow_session)
  {:noreply, socket}
end
```

Place it in the session management events section (after `mark_undone` or alongside the other session events).

### Step 5: Update `render_phase/1` in WorkflowRunnerLive

**File: `lib/destila_web/live/workflow_runner_live.ex`**

Replace the `<.live_component>` call with a direct function component call.

Before:
```elixir
defp render_phase(%{workflow_session: %{phase_status: :setup}} = assigns) do
  ~H"""
  <.live_component
    module={DestilaWeb.Phases.SetupPhase}
    id="setup"
    workflow_session={@workflow_session}
    metadata={@metadata}
    phase_number={0}
    opts={[]}
  />
  """
end
```

After:
```elixir
defp render_phase(%{workflow_session: %{phase_status: :setup}} = assigns) do
  ~H"""
  <DestilaWeb.Phases.SetupPhase.setup_phase
    workflow_session={@workflow_session}
    metadata={@metadata}
  />
  """
end
```

Note: `phase_number` and `opts` are no longer passed — they were only needed by the LiveComponent lifecycle and are unused by the function component.

## Files to modify

1. **`lib/destila_web/live/phases/setup_phase.ex`** — Convert from LiveComponent to function component, remove DB query, remove `phx-target`
2. **`lib/destila_web/live/workflow_runner_live.ex`** — Add `retry_setup` handler, update `render_phase/1` call

## Files confirmed unchanged

1. **`lib/destila/workflows.ex`** — `prepare_workflow_session/1` is called from the new location in WorkflowRunnerLive, no changes needed
2. **Feature files** — user-visible behavior is identical; no Gherkin changes needed
3. **Tests** — no existing tests reference `SetupPhase` directly
4. **All other phase modules** — no references to `SetupPhase`

## Risks and mitigations

1. **Render-time computation in `build_steps/2`** — previously computed in `update/2` (on every assign change), now computed on every render. The function is trivial (no DB calls after step 2), so this has no performance impact.

2. **Event routing** — removing `phx-target` means the `retry_setup` event now routes to the LiveView process instead of the LiveComponent. This is correct because the handler is being moved to `WorkflowRunnerLive`. If the handler is missing, LiveView will raise at runtime — the handler must be added before/alongside the component change.
