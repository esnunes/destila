---
title: "feat: GenServer aliveness indicator for workflow sessions"
type: feat
date: 2026-04-02
---

# feat: GenServer aliveness indicator for workflow sessions

## Overview

Add a visual indicator (colored dot) showing whether the Claude Code GenServer backing a workflow session is actually running. This gives operators immediate visibility into process health without needing to check a remote shell.

The indicator has three states:
- **Green** — GenServer is alive (process running)
- **Gray** — GenServer is not running, and this is expected (session not in an AI phase or not processing)
- **Red** — GenServer is not running, but it should be (session is in an AI phase AND has `phase_status == :processing`)

It appears in two places: session cards on the crafting board, and the workflow runner header.

## Solution

Use PubSub for process discovery and `Process.monitor/1` for death detection. This is chosen over `terminate/2` callbacks because monitors guarantee `:DOWN` delivery even on brutal kills.

### Architecture

1. **GenServer broadcasts on start** — `ClaudeSession.init/1` broadcasts `{:claude_session_started, workflow_session_id}` to a dedicated PubSub topic so LiveViews can discover new processes.

2. **LiveViews look up + monitor on mount** — On connected mount, each LiveView looks up relevant session GenServer PIDs via `Destila.AI.SessionRegistry` and calls `Process.monitor/1`. Tracks liveness in an assign `%{workflow_session_id => true}`.

3. **LiveViews handle PubSub start events** — When `{:claude_session_started, ws_id}` arrives, look up the PID from Registry, monitor it, and mark alive.

4. **LiveViews handle `:DOWN` messages** — Remove the session from the alive map, triggering re-render with gray or red dot.

### Key design decisions

1. **Dedicated PubSub topic** (`"claude_sessions"`) — Keeps aliveness signals out of the `"store:updates"` topic, which is broadcast-heavy and consumed broadly. LiveViews that don't need aliveness don't subscribe.

2. **Assign-based tracking, not stream metadata** — The crafting board uses regular assigns (not streams) for session lists, so a separate `%{ws_id => true}` map is clean and efficient. The workflow runner only tracks a single session.

3. **Helper module** (`Destila.AI.ClaudeSession.Liveness`) is NOT needed — the logic is simple enough to inline. A `liveness_topic/0` function on `PubSubHelper` is sufficient.

4. **Determination of "expected" vs "unexpected" down** — The check is: is the session's current phase backed by `AiConversationPhase` AND is `phase_status == :processing`? If both, red. Otherwise gray. This logic lives in a helper function in `BoardComponents` since both LiveViews need it. **Important:** `SetupPhase` does NOT use `ClaudeSession` — it uses separate Oban workers (`SetupWorker`, `TitleGenerationWorker`) that do git operations and one-off `ClaudeCode.start_link` calls. Only `AiConversationPhase` phases create persistent `ClaudeSession` GenServers via `AiQueryWorker.for_workflow_session/2`.

5. **No polling** — Real-time updates only via PubSub and OTP monitors.

## Files to Modify

1. **`lib/destila/pub_sub_helper.ex`** — Add `claude_session_topic/0` helper
2. **`lib/destila/ai/claude_session.ex`** — Broadcast start event in `init/1`
3. **`lib/destila_web/components/board_components.ex`** — Add `.aliveness_dot` component and `should_be_alive?/1` helper
4. **`lib/destila_web/live/crafting_board_live.ex`** — Subscribe, monitor, handle start/DOWN, pass liveness to cards
5. **`lib/destila_web/live/workflow_runner_live.ex`** — Subscribe, monitor, handle start/DOWN, render indicator in header
6. **`features/crafting_board.feature`** — Add aliveness indicator scenarios
7. **`features/brainstorm_idea_workflow.feature`** — Add aliveness indicator scenarios for workflow runner
8. **`test/destila_web/live/crafting_board_live_test.exs`** — Add tests for new scenarios
9. **`test/destila_web/live/brainstorm_idea_workflow_live_test.exs`** — Add tests for new scenarios

## Implementation Steps

### Step 1: Add PubSub topic helper

In `lib/destila/pub_sub_helper.ex`, add a function for the aliveness topic:

```elixir
def claude_session_topic, do: "claude_sessions"
```

### Step 2: Broadcast start event from ClaudeSession

In `lib/destila/ai/claude_session.ex`, modify `init/1` to broadcast after successful startup. The workflow_session_id must be extracted from the GenServer's registered name.

Add at the end of the successful `init/1` path (after `{:ok, %{claude_session: ..., timeout_ms: ..., timer_ref: ...}}`):

```elixir
# In init/1, after creating the state map:
# Extract workflow_session_id from the Registry name if registered
workflow_session_id = extract_workflow_session_id()

state = %{
  claude_session: claude_session,
  timeout_ms: timeout_ms,
  timer_ref: timer_ref,
  workflow_session_id: workflow_session_id
}

if workflow_session_id do
  Phoenix.PubSub.broadcast(
    Destila.PubSub,
    Destila.PubSubHelper.claude_session_topic(),
    {:claude_session_started, workflow_session_id}
  )
end

{:ok, state}
```

The `workflow_session_id` needs to be passed through from the caller. The simplest approach: add it as an option extracted in `init/1`. Since `for_workflow_session/2` already knows the ID, it can pass it as `workflow_session_id: workflow_session_id` in the opts:

In `for_workflow_session/2`, the `start_link` call already passes opts. Add:
```elixir
opts = Keyword.put(opts, :workflow_session_id, workflow_session_id)
```

In `init/1`, extract it:
```elixir
{workflow_session_id, claude_opts} = Keyword.pop(claude_opts, :workflow_session_id)
```

Store it in state for potential future use, and broadcast after successful init.

### Step 3: Add aliveness_dot component and should_be_alive? helper

In `lib/destila_web/components/board_components.ex`, add:

```elixir
attr :session, :map, required: true
attr :alive?, :boolean, required: true

def aliveness_dot(assigns) do
  assigns = assign(assigns, :aliveness_state, aliveness_state(assigns.session, assigns.alive?))

  ~H"""
  <span
    title={aliveness_title(@aliveness_state)}
    class={["inline-flex size-2 shrink-0 rounded-full", aliveness_color(@aliveness_state)]}
  />
  """
end

defp aliveness_state(_session, true), do: :alive

defp aliveness_state(session, false) do
  if should_be_alive?(session), do: :unexpected_down, else: :expected_down
end

@doc """
Returns true if the session is in a state where a GenServer should be running.
An AI-related phase with :processing status means the GenServer should be active.
"""
def should_be_alive?(%{phase_status: :processing} = session) do
  ai_phase?(session)
end

def should_be_alive?(_session), do: false

defp ai_phase?(session) do
  # Only AiConversationPhase uses ClaudeSession GenServer.
  # SetupPhase does NOT — it uses separate Oban workers (SetupWorker, TitleGenerationWorker).
  case Destila.Workflows.phases(session.workflow_type)
       |> Enum.at(session.current_phase - 1) do
    {DestilaWeb.Phases.AiConversationPhase, _opts} -> true
    _ -> false
  end
end

defp aliveness_color(:alive), do: "bg-success"
defp aliveness_color(:expected_down), do: "bg-base-content/20"
defp aliveness_color(:unexpected_down), do: "bg-error animate-pulse"

defp aliveness_title(:alive), do: "AI session running"
defp aliveness_title(:expected_down), do: "AI session idle"
defp aliveness_title(:unexpected_down), do: "AI session not running (unexpected)"
```

### Step 4: Update CraftingBoardLive

Modify `lib/destila_web/live/crafting_board_live.ex`:

**4a. Subscribe to aliveness topic on mount:**

In `mount/3`, after the existing PubSub subscription:
```elixir
if connected?(socket) do
  Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
  Phoenix.PubSub.subscribe(Destila.PubSub, Destila.PubSubHelper.claude_session_topic())
end
```

**4b. Add initial aliveness lookup and monitoring:**

Add a helper that monitors all currently-alive GenServers for the sessions on the board. Call it after loading sessions in `handle_params`. **Important:** Guard with `connected?(socket)` since `handle_params` runs on both disconnected and connected mounts — monitoring on the short-lived disconnected mount is wasteful:

```elixir
defp monitor_alive_sessions(socket) do
  # Only monitor on connected mount — the disconnected render process is short-lived
  if not connected?(socket) do
    socket
  else
    sessions = socket.assigns.all_prompts
    alive_map = socket.assigns[:alive_sessions] || %{}
    monitored = socket.assigns[:monitored_refs] || %{}

    Enum.reduce(sessions, {alive_map, monitored}, fn session, {alive, refs} ->
      # Skip if already monitored
      if Map.has_key?(alive, session.id) do
        {alive, refs}
      else
        name = {:via, Registry, {Destila.AI.SessionRegistry, session.id}}
        case GenServer.whereis(name) do
          nil ->
            {alive, refs}
          pid ->
            ref = Process.monitor(pid)
            {Map.put(alive, session.id, true), Map.put(refs, ref, session.id)}
        end
      end
    end)
    |> then(fn {alive, refs} ->
      socket
      |> assign(:alive_sessions, alive)
      |> assign(:monitored_refs, refs)
    end)
  end
end
```

Call `monitor_alive_sessions` in `handle_params` after assigning `all_prompts`, and also initialize the assigns:

```elixir
# In mount, add initial assigns:
|> assign(:alive_sessions, %{})
|> assign(:monitored_refs, %{})
```

```elixir
# In handle_params, after assign_derived_state:
|> monitor_alive_sessions()
```

**4c. Handle :claude_session_started and :DOWN:**

**CRITICAL: Clause ordering.** Both `CraftingBoardLive` and `WorkflowRunnerLive` have a catch-all `def handle_info(_msg, socket), do: {:noreply, socket}` at the bottom. The new `:claude_session_started` and `:DOWN` handlers MUST be placed BEFORE this catch-all, otherwise they will never match. Place them immediately before the catch-all clause.

```elixir
# Place BEFORE the catch-all `def handle_info(_msg, socket)`
def handle_info({:claude_session_started, ws_id}, socket) do
  name = {:via, Registry, {Destila.AI.SessionRegistry, ws_id}}

  case GenServer.whereis(name) do
    nil ->
      {:noreply, socket}

    pid ->
      ref = Process.monitor(pid)

      {:noreply,
       socket
       |> update(:alive_sessions, &Map.put(&1, ws_id, true))
       |> update(:monitored_refs, &Map.put(&1, ref, ws_id))}
  end
end

def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
  case Map.get(socket.assigns.monitored_refs, ref) do
    nil ->
      {:noreply, socket}

    ws_id ->
      {:noreply,
       socket
       |> update(:alive_sessions, &Map.delete(&1, ws_id))
       |> update(:monitored_refs, &Map.delete(&1, ref))}
  end
end
```

**4e. Pass alive status to crafting_card:**

In the template, pass `alive?` to the card. There are two places in `crafting_board_live.ex`:

1. **List view** (line ~259): Add `alive?` attr to the non-compact card:
```heex
<.crafting_card
  :for={card <- @sections[section]}
  card={card}
  project_filter={@project_filter}
  alive?={Map.get(@alive_sessions, card.id, false)}
/>
```

2. **Workflow view** (line ~304): Add `alive?` attr to the compact card:
```heex
<.crafting_card
  :for={card <- col_prompts}
  card={card}
  project_filter={@project_filter}
  compact
  alive?={Map.get(@alive_sessions, card.id, false)}
/>
```

**4f. Update crafting_card to render aliveness_dot:**

In `board_components.ex`:

1. Add attribute declaration (after `attr :compact` on line 40):
```elixir
attr :alive?, :boolean, default: false
```

2. **Compact card** — In the compact layout (line 63), the `.status_dot` is rendered next to the title. Wrap the status dot and aliveness dot together:

**Current (line 63):**
```heex
<.status_dot :if={@compact} card={@card} />
```

**Replace with:**
```heex
<div :if={@compact} class="flex items-center gap-1 shrink-0">
  <.aliveness_dot session={@card} alive?={@alive?} />
  <.status_dot card={@card} />
</div>
```

3. **Non-compact card** — In the non-compact layout (line 71-90), add the aliveness dot at the start of the badge/project row.

**Current (line 72):**
```heex
<div class="flex items-center gap-2">
  <.workflow_badge type={@card.workflow_type} />
```

**Replace with:**
```heex
<div class="flex items-center gap-2">
  <.aliveness_dot session={@card} alive?={@alive?} />
  <.workflow_badge type={@card.workflow_type} />
```

### Step 5: Update WorkflowRunnerLive

Modify `lib/destila_web/live/workflow_runner_live.ex`:

**5a. Subscribe and monitor on mount (session path only):**

In `mount_session/2`, after the existing PubSub subscriptions:
```elixir
Phoenix.PubSub.subscribe(Destila.PubSub, Destila.PubSubHelper.claude_session_topic())

# Look up and monitor the current GenServer
alive_session =
  case GenServer.whereis({:via, Registry, {Destila.AI.SessionRegistry, id}}) do
    nil -> false
    pid ->
      Process.monitor(pid)
      true
  end
```

Add to assigns:
```elixir
|> assign(:alive_session, alive_session)
```

For the non-session mount paths (`mount_workflow`, `mount_type_selection`), assign `:alive_session` to `false`.

**5b. Handle :claude_session_started and :DOWN:**

**CRITICAL: Clause ordering.** Same as CraftingBoardLive — place these BEFORE the catch-all `def handle_info(_msg, socket)` at the bottom of `WorkflowRunnerLive`.

Use ref tracking to safely identify which `:DOWN` messages are ours (the LiveView process or test stubs may receive other `:DOWN` messages from ClaudeCode.Test stubs):

```elixir
# Place BEFORE the catch-all `def handle_info(_msg, socket)`
def handle_info({:claude_session_started, ws_id}, socket) do
  if socket.assigns[:workflow_session] && ws_id == socket.assigns.workflow_session.id do
    name = {:via, Registry, {Destila.AI.SessionRegistry, ws_id}}

    case GenServer.whereis(name) do
      nil ->
        {:noreply, socket}

      pid ->
        ref = Process.monitor(pid)
        {:noreply, assign(socket, alive_session: true, alive_session_ref: ref)}
    end
  else
    {:noreply, socket}
  end
end

def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
  if ref == socket.assigns[:alive_session_ref] do
    {:noreply, assign(socket, alive_session: false, alive_session_ref: nil)}
  else
    {:noreply, socket}
  end
end
```

Add `alive_session_ref` to all mount paths:

```elixir
# In mount_session, store the ref when monitoring:
{alive_session, alive_session_ref} =
  case GenServer.whereis({:via, Registry, {Destila.AI.SessionRegistry, id}}) do
    nil -> {false, nil}
    pid -> {true, Process.monitor(pid)}
  end
```

```elixir
|> assign(:alive_session, alive_session)
|> assign(:alive_session_ref, alive_session_ref)
```

```elixir
# In mount_workflow and mount_type_selection:
|> assign(:alive_session, false)
|> assign(:alive_session_ref, nil)
```

**5d. Render in header:**

In `workflow_runner_live.ex`, add the aliveness dot in the header next to the title. The indicator should only render when we have a workflow_session (not on the type selection page or pre-session phase 1).

**Current template structure (line 365):**
```heex
<div :if={!@editing_title} class="flex items-center gap-2">
  <h1 class={[...]} phx-click={...}>
    {@workflow_session.title}
  </h1>
  <button ...>
    <.icon name="hero-pencil-micro" ... />
  </button>
</div>
```

**Add aliveness dot before the `<h1>` tag:**
```heex
<div :if={!@editing_title} class="flex items-center gap-2">
  <.aliveness_dot session={@workflow_session} alive?={@alive_session} />
  <h1 class={[...]} phx-click={...}>
    {@workflow_session.title}
  </h1>
  <button ...>
    <.icon name="hero-pencil-micro" ... />
  </button>
</div>
```

This is inside the `<%= if @workflow_session do %>` block (line 364), so the dot only renders when a session exists.

**Update the import** (line 14):

```elixir
# Current:
import DestilaWeb.BoardComponents, only: [workflow_badge: 1, progress_indicator: 1]

# Replace with:
import DestilaWeb.BoardComponents, only: [workflow_badge: 1, progress_indicator: 1, aliveness_dot: 1]
```

### Step 6: Update Gherkin feature files

**6a. `features/crafting_board.feature`** — Append after the last scenario:

```gherkin
  # --- Aliveness Indicator ---

  Scenario: Session card shows green indicator when Claude Code GenServer is running
    Given there is a session with an active Claude Code GenServer
    When I navigate to the crafting board
    Then the session card should show a green aliveness indicator

  Scenario: Session card shows gray indicator when GenServer is not running and not expected
    Given there is a session whose Claude Code GenServer is not running
    And the session is not in an AI-related phase or not in processing status
    When I navigate to the crafting board
    Then the session card should show a gray aliveness indicator

  Scenario: Session card shows red indicator when GenServer is unexpectedly not running
    Given there is a session in an AI-related phase with processing status
    And the session's Claude Code GenServer is not running
    When I navigate to the crafting board
    Then the session card should show a red aliveness indicator

  Scenario: Session card indicator updates when GenServer stops
    Given I am on the crafting board
    And a session has a running Claude Code GenServer with a green indicator
    When the Claude Code GenServer for that session stops
    Then the session card indicator should change from green to the appropriate state
```

**6b. `features/brainstorm_idea_workflow.feature`** — Append after the last scenario:

```gherkin
  Scenario: Workflow runner shows green indicator when Claude Code GenServer is running
    Given I am on a session detail page
    And the session has an active Claude Code GenServer
    Then I should see a green aliveness indicator in the session header

  Scenario: Workflow runner shows gray indicator when GenServer is not expected
    Given I am on a session detail page
    And the session is not in an AI-related phase or not in processing status
    And the session's Claude Code GenServer is not running
    Then I should see a gray aliveness indicator in the session header

  Scenario: Workflow runner shows red indicator when GenServer is unexpectedly not running
    Given I am on a session detail page
    And the session is in an AI-related phase with processing status
    And the session's Claude Code GenServer is not running
    Then I should see a red aliveness indicator in the session header

  Scenario: Workflow runner indicator updates in real-time when GenServer stops
    Given I am on a session detail page
    And the session has a running Claude Code GenServer with a green indicator
    When the Claude Code GenServer stops
    Then the indicator should update to reflect the current state
```

### Step 7: Add tests

**Strategy:** Use `Agent.start_link/2` registered in `Destila.AI.SessionRegistry` to simulate a running ClaudeSession GenServer. This is lightweight, doesn't require real ClaudeCode, and the LiveView discovers it via the same Registry lookup used in production. Use `start_supervised!/1` for cleanup.

**7a. CraftingBoardLive tests** — Add a new describe block in `test/destila_web/live/crafting_board_live_test.exs`:

```elixir
describe "aliveness indicator" do
  @tag feature: @feature,
       scenario: "Session card shows gray indicator when GenServer is not running and not expected"
  test "shows gray dot when GenServer is not running and not expected", %{
    conn: conn,
    project_a: project
  } do
    # Session in awaiting_input (not processing) — gray is expected
    ws = create_prompt(%{title: "Idle Session", project_id: project.id, phase_status: :awaiting_input})

    {:ok, view, _html} = live(conn, ~p"/crafting")

    # Aliveness dot should be gray (bg-base-content/20)
    assert has_element?(view, "#crafting-card-#{ws.id} span[title='AI session idle']")
  end

  @tag feature: @feature,
       scenario: "Session card shows red indicator when GenServer is unexpectedly not running"
  test "shows red dot when GenServer should be running but is not", %{
    conn: conn,
    project_a: project
  } do
    # Session in phase 3 (AiConversationPhase) with processing status — red expected
    ws =
      create_prompt(%{
        title: "Stuck Session",
        project_id: project.id,
        current_phase: 3,
        phase_status: :processing,
        workflow_type: :brainstorm_idea
      })

    {:ok, view, _html} = live(conn, ~p"/crafting")

    # Aliveness dot should be red (bg-error)
    assert has_element?(
             view,
             "#crafting-card-#{ws.id} span[title='AI session not running (unexpected)']"
           )
  end

  @tag feature: @feature,
       scenario: "Session card shows green indicator when Claude Code GenServer is running"
  test "shows green dot when GenServer is running", %{conn: conn, project_a: project} do
    ws =
      create_prompt(%{
        title: "Active Session",
        project_id: project.id,
        current_phase: 3,
        phase_status: :processing,
        workflow_type: :brainstorm_idea
      })

    # Register a dummy Agent in the SessionRegistry to simulate a running GenServer
    start_supervised!(
      {Agent,
       fn -> nil end
       |> then(fn f ->
         %{
           id: {:test_agent, ws.id},
           start:
             {Agent, :start_link, [f, [name: {:via, Registry, {Destila.AI.SessionRegistry, ws.id}}]]}
         }
       end)}
    )

    {:ok, view, _html} = live(conn, ~p"/crafting")

    # Aliveness dot should be green (bg-success)
    assert has_element?(view, "#crafting-card-#{ws.id} span[title='AI session running']")
  end

  @tag feature: @feature, scenario: "Session card indicator updates when GenServer stops"
  test "updates from green to red when GenServer stops", %{conn: conn, project_a: project} do
    ws =
      create_prompt(%{
        title: "Active Session",
        project_id: project.id,
        current_phase: 3,
        phase_status: :processing,
        workflow_type: :brainstorm_idea
      })

    # Start a dummy Agent registered as the session's GenServer
    {:ok, pid} =
      Agent.start_link(fn -> nil end,
        name: {:via, Registry, {Destila.AI.SessionRegistry, ws.id}}
      )

    {:ok, view, _html} = live(conn, ~p"/crafting")

    # Should be green initially
    assert has_element?(view, "#crafting-card-#{ws.id} span[title='AI session running']")

    # Stop the agent — triggers :DOWN in the LiveView
    Agent.stop(pid)

    # Wait for the :DOWN message to be processed
    _ = render(view)

    # Should now be red (processing + AiConversationPhase but no GenServer)
    assert has_element?(
             view,
             "#crafting-card-#{ws.id} span[title='AI session not running (unexpected)']"
           )
  end
end
```

**7b. WorkflowRunnerLive tests** — Add to `test/destila_web/live/brainstorm_idea_workflow_live_test.exs`:

```elixir
describe "aliveness indicator" do
  @tag feature: @feature,
       scenario: "Workflow runner shows gray indicator when GenServer is not expected"
  test "shows gray dot when GenServer is not running and not expected", %{conn: conn} do
    ws = create_session_in_phase(3, phase_status: :awaiting_input)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "span[title='AI session idle']")
  end

  @tag feature: @feature,
       scenario: "Workflow runner shows red indicator when GenServer is unexpectedly not running"
  test "shows red dot when GenServer should be running but is not", %{conn: conn} do
    ws = create_session_in_phase(3, phase_status: :processing)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "span[title='AI session not running (unexpected)']")
  end

  @tag feature: @feature,
       scenario: "Workflow runner shows green indicator when Claude Code GenServer is running"
  test "shows green dot when GenServer is running", %{conn: conn} do
    ws = create_session_in_phase(3, phase_status: :processing)

    {:ok, _pid} =
      Agent.start_link(fn -> nil end,
        name: {:via, Registry, {Destila.AI.SessionRegistry, ws.id}}
      )

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "span[title='AI session running']")
  end

  @tag feature: @feature,
       scenario: "Workflow runner indicator updates in real-time when GenServer stops"
  test "updates from green to red when GenServer stops", %{conn: conn} do
    ws = create_session_in_phase(3, phase_status: :processing)

    {:ok, pid} =
      Agent.start_link(fn -> nil end,
        name: {:via, Registry, {Destila.AI.SessionRegistry, ws.id}}
      )

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "span[title='AI session running']")

    # Stop the agent — triggers :DOWN
    Agent.stop(pid)
    _ = render(view)

    assert has_element?(view, "span[title='AI session not running (unexpected)']")
  end
end
```

**Note on `start_supervised!` vs manual `Agent.start_link`:** For the green → red transition test, we use manual `Agent.start_link` (not `start_supervised!`) because we need to explicitly stop the agent mid-test to trigger the `:DOWN` message. `start_supervised!` stops agents only after the test ends, which is too late. The agent will be cleaned up by the test process exit anyway.

### Step 8: Run `mix precommit`

Verify compilation, formatting, and all tests pass.

## Edge Cases

### GenServer starts after LiveView mount

If the GenServer starts after the LiveView has already mounted and done its initial Registry lookup, the PubSub `{:claude_session_started, ws_id}` message will notify the LiveView. The LiveView then looks up the PID from Registry and monitors it.

### GenServer restarts (temporary process)

The `child_spec` sets `restart: :temporary`, so GenServers that crash are NOT restarted by the DynamicSupervisor. A new one is created by the next `for_workflow_session/2` call (typically from the AiQueryWorker). When the new GenServer starts, it broadcasts `{:claude_session_started, ...}`, which the LiveView picks up.

### Race: PID dies between Registry lookup and Process.monitor

`Process.monitor/1` handles this: if the process is already dead when you call `monitor/1`, you immediately receive a `:DOWN` message. No race condition.

### Multiple tabs/LiveViews

Each LiveView independently subscribes, monitors, and tracks liveness. Since `Process.monitor/1` is per-process, each LiveView gets its own `:DOWN` message. The PubSub broadcast is received by all subscribers. No coordination needed.

### Session without a workflow_session_id (standalone ClaudeSession)

The broadcast only fires when `workflow_session_id` is non-nil (i.e., when started via `for_workflow_session/2`). Standalone sessions (if any exist) don't trigger the broadcast. This is correct — they have no session card to show an indicator for.

### Crafting board page refresh while GenServer is running

On mount, the LiveView does a fresh Registry lookup for all sessions. It finds and monitors any running GenServers. The indicator immediately shows green.

## Corrections from deepening review

The following issues were identified and corrected during the plan deepening pass:

1. **SetupPhase incorrectly included in `ai_phase?`** — SetupPhase does NOT use `ClaudeSession`. It uses separate Oban workers (`SetupWorker` for git ops, `TitleGenerationWorker` for one-off `ClaudeCode.start_link` calls). Only `AiConversationPhase` creates persistent `ClaudeSession` GenServers. Removed SetupPhase from `ai_phase?`.

2. **`handle_info` clause ordering** — Both LiveViews have a catch-all `def handle_info(_msg, socket)` that would silently swallow the new `:claude_session_started` and `:DOWN` messages if the new handlers were placed after it. Added explicit ordering requirement.

3. **`monitor_alive_sessions` on disconnected mount** — `handle_params` runs on both disconnected and connected mounts. Monitoring on the short-lived disconnected render is wasteful. Added `connected?(socket)` guard.

4. **WorkflowRunnerLive `:DOWN` safety** — The original plan assumed any `:DOWN` corresponds to the session's GenServer, but test stubs or other monitored processes could send spurious `:DOWN` messages. Added ref tracking (`alive_session_ref`) to match only our monitors.

5. **Missing concrete test code** — Replaced bullet-point test descriptions with complete ExUnit test implementations including `@tag` annotations, Agent-based GenServer simulation, and green→red transition tests.

6. **Template placement specifics** — Added exact line numbers and before/after code for where to insert the aliveness dot in both `board_components.ex` and `workflow_runner_live.ex` templates.

## Verification

1. `mix precommit` passes
2. Manual test: Start a session that triggers AI processing → indicator shows green during processing
3. Manual test: Wait for AI processing to finish → indicator transitions to gray
4. Manual test: Kill a GenServer via remote shell while session is processing → indicator shows red
5. Manual test: Navigate to crafting board with running sessions → green dots appear
6. Manual test: Archive a session (which stops its GenServer) → indicator updates
