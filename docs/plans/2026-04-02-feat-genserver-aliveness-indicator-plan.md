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

4. **Determination of "expected" vs "unexpected" down** — The check is: is the session's current phase backed by `AiConversationPhase` (or `SetupPhase` which also uses AI) AND is `phase_status == :processing`? If both, red. Otherwise gray. This logic lives in a helper function in `BoardComponents` since both LiveViews need it.

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
  # Check if the session's current phase uses AiConversationPhase
  case Destila.Workflows.phases(session.workflow_type)
       |> Enum.at(session.current_phase - 1) do
    {DestilaWeb.Phases.AiConversationPhase, _opts} -> true
    {DestilaWeb.Phases.SetupPhase, _opts} -> true
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

Add a helper that monitors all currently-alive GenServers for the sessions on the board. Call it after loading sessions in `handle_params`:

```elixir
defp monitor_alive_sessions(socket) do
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

**4c. Handle :claude_session_started:**

```elixir
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
```

**4d. Handle :DOWN:**

```elixir
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

In the template, pass `alive?` to the card:

```heex
<.crafting_card
  :for={card <- @sections[section]}
  card={card}
  project_filter={@project_filter}
  alive?={Map.get(@alive_sessions, card.id, false)}
/>
```

Same for compact cards in workflow view.

**4f. Update crafting_card to render aliveness_dot:**

Add `attr :alive?, :boolean, default: false` to `crafting_card`.

In the compact card layout (where `.status_dot` is rendered), add `.aliveness_dot` next to it:

```heex
<div class="flex items-center gap-1">
  <.aliveness_dot session={@card} alive?={@alive?} />
  <.status_dot :if={@compact} card={@card} />
</div>
```

In the non-compact card layout, add the aliveness dot near the workflow badge:

```heex
<div class="flex items-center gap-2">
  <.aliveness_dot session={@card} alive?={@alive?} />
  <.workflow_badge type={@card.workflow_type} />
  ...
</div>
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

**5b. Handle :claude_session_started:**

```elixir
def handle_info({:claude_session_started, ws_id}, socket) do
  if socket.assigns[:workflow_session] && ws_id == socket.assigns.workflow_session.id do
    name = {:via, Registry, {Destila.AI.SessionRegistry, ws_id}}

    case GenServer.whereis(name) do
      nil ->
        {:noreply, socket}

      pid ->
        Process.monitor(pid)
        {:noreply, assign(socket, :alive_session, true)}
    end
  else
    {:noreply, socket}
  end
end
```

**5c. Handle :DOWN:**

```elixir
def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
  {:noreply, assign(socket, :alive_session, false)}
end
```

Note: Since WorkflowRunnerLive only monitors a single session's GenServer, any `:DOWN` message corresponds to that session. No ref tracking needed.

**5d. Render in header:**

In the header area, add the aliveness dot next to the title. After the `<h1>` tag that shows the session title:

```heex
<div :if={!@editing_title} class="flex items-center gap-2">
  <.aliveness_dot session={@workflow_session} alive?={@alive_session} />
  <h1 ...>
    {@workflow_session.title}
  </h1>
  ...
</div>
```

Import `aliveness_dot` from `BoardComponents` — it's already imported via `import DestilaWeb.BoardComponents, only: [workflow_badge: 1, progress_indicator: 1]`. Extend the import:

```elixir
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

**7a. CraftingBoardLive tests** — Add tests that verify the aliveness dot is rendered with appropriate state classes based on session state. Since we can't easily start a real ClaudeCode GenServer in tests, test the component rendering:

- Test that `aliveness_dot` renders with `bg-base-content/20` (gray) when no GenServer is running and session is not in AI phase with processing status
- Test that `aliveness_dot` renders with `bg-error` (red) when no GenServer running but session is in AI phase with processing status
- Test that the crafting card passes through the `alive?` attribute

For the green state, we can use a simple GenServer in the test:

```elixir
# Start a dummy GenServer registered in the SessionRegistry
{:ok, pid} = Agent.start_link(fn -> nil end,
  name: {:via, Registry, {Destila.AI.SessionRegistry, ws.id}})
```

This lets the LiveView discover it via Registry and monitor it. Then stopping the agent tests the `:DOWN` transition.

**7b. WorkflowRunnerLive tests** — Similar approach: verify the aliveness dot renders in the header with appropriate classes.

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

## Verification

1. `mix precommit` passes
2. Manual test: Start a session that triggers AI processing → indicator shows green during processing
3. Manual test: Wait for AI processing to finish → indicator transitions to gray
4. Manual test: Kill a GenServer via remote shell while session is processing → indicator shows red
5. Manual test: Navigate to crafting board with running sessions → green dots appear
6. Manual test: Archive a session (which stops its GenServer) → indicator updates
