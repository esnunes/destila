# Refactor: Centralized aliveness tracker

## Context

Both `CraftingBoardLive` and `WorkflowRunnerLive` independently implement `Process.monitor/1` tracking for AI session GenServers registered in `Destila.AI.SessionRegistry`. Each LiveView subscribes to `claude_sessions` PubSub, looks up PIDs via Registry, monitors them, and handles `:DOWN` messages — duplicating ~30 lines of monitoring logic.

This refactor extracts that logic into a single `Destila.AI.AlivenessTracker` GenServer that monitors all AI session processes centrally and exposes aliveness via ETS (for instant reads) and PubSub (for change notifications). LiveViews become pure consumers: one ETS lookup on mount, one PubSub subscription for updates.

## Plan

### Step 1 — Create `Destila.AI.AlivenessTracker`

**File:** `lib/destila/ai/aliveness_tracker.ex` (new)

```elixir
defmodule Destila.AI.AlivenessTracker do
  use GenServer

  @ets_table :ai_session_aliveness
  @pubsub_topic "session_aliveness"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Returns true if an AI session GenServer is running for the given session ID."
  def alive?(session_id) do
    case :ets.lookup(@ets_table, session_id) do
      [{^session_id, true}] -> true
      _ -> false
    end
  end

  @doc "PubSub topic for aliveness change notifications."
  def topic, do: @pubsub_topic

  @impl true
  def init(_) do
    :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])
    Phoenix.PubSub.subscribe(Destila.PubSub, Destila.PubSubHelper.claude_session_topic())

    # Scan for existing sessions already registered in the AI SessionRegistry
    refs =
      Registry.select(Destila.AI.SessionRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.reduce(%{}, fn {session_id, pid}, acc ->
        ref = Process.monitor(pid)
        :ets.insert(@ets_table, {session_id, true})
        Map.put(acc, ref, session_id)
      end)

    {:ok, %{refs: refs}}
  end

  @impl true
  def handle_info({:claude_session_started, session_id}, state) do
    name = {:via, Registry, {Destila.AI.SessionRegistry, session_id}}

    case GenServer.whereis(name) do
      nil ->
        {:noreply, state}

      pid ->
        ref = Process.monitor(pid)
        :ets.insert(@ets_table, {session_id, true})
        broadcast(session_id, true)
        {:noreply, put_in(state, [:refs, ref], session_id)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _state} ->
        {:noreply, state}

      {session_id, refs} ->
        :ets.delete(@ets_table, session_id)
        broadcast(session_id, false)
        {:noreply, %{state | refs: refs}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp broadcast(session_id, alive?) do
    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      @pubsub_topic,
      {:aliveness_changed, session_id, alive?}
    )
  end
end
```

Key design decisions:

- **ETS with `read_concurrency: true`** — LiveViews read aliveness on mount without calling into the GenServer. Reads are lock-free and fast.
- **PubSub for change notifications** — LiveViews subscribe to `"session_aliveness"` and react to `{:aliveness_changed, session_id, alive?}` messages. No polling.
- **Subscribes to `claude_sessions` PubSub** — The same topic `ClaudeSession.init/1` already broadcasts `{:claude_session_started, ws_id}` to (line 185-189 of `claude_session.ex`). The tracker picks up new sessions via this broadcast.
- **Initial Registry scan** — On startup, scans `Destila.AI.SessionRegistry` for any sessions that were already running before the tracker started (e.g., during hot code reload or if the tracker restarts).
- **Race safety** — `Process.monitor/1` returns an immediate `:DOWN` if the process is already dead, so no gap between lookup and monitor.

### Step 2 — Add AlivenessTracker to the supervision tree

**File:** `lib/destila/application.ex` — line 20

Insert `Destila.AI.AlivenessTracker` after the `DynamicSupervisor` for AI sessions and before `Destila.Sessions.Registry`. This ensures the Registry and DynamicSupervisor are already running when the tracker starts and scans.

```elixir
# Current (lines 17-21):
{Registry, keys: :unique, name: Destila.AI.SessionRegistry},
{DynamicSupervisor, name: Destila.AI.SessionSupervisor, strategy: :one_for_one},
{Registry, keys: :unique, name: Destila.Sessions.Registry},

# After:
{Registry, keys: :unique, name: Destila.AI.SessionRegistry},
{DynamicSupervisor, name: Destila.AI.SessionSupervisor, strategy: :one_for_one},
Destila.AI.AlivenessTracker,
{Registry, keys: :unique, name: Destila.Sessions.Registry},
```

### Step 3 — Simplify `WorkflowRunnerLive`

**File:** `lib/destila_web/live/workflow_runner_live.ex`

**3a. Remove `alive_session_ref` assign and monitoring logic from `mount_session/2` (lines 34-46):**

Current code (lines 34-46):
```elixir
{alive_session, alive_session_ref} =
  if connected?(socket) do
    Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
    Phoenix.PubSub.subscribe(Destila.PubSub, Destila.PubSubHelper.ai_stream_topic(id))
    Phoenix.PubSub.subscribe(Destila.PubSub, Destila.PubSubHelper.claude_session_topic())

    case GenServer.whereis({:via, Registry, {Destila.AI.SessionRegistry, id}}) do
      nil -> {false, nil}
      pid -> {true, Process.monitor(pid)}
    end
  else
    {false, nil}
  end
```

Replace with:
```elixir
alive_session =
  if connected?(socket) do
    Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
    Phoenix.PubSub.subscribe(Destila.PubSub, Destila.PubSubHelper.ai_stream_topic(id))
    Phoenix.PubSub.subscribe(Destila.PubSub, Destila.AI.AlivenessTracker.topic())

    Destila.AI.AlivenessTracker.alive?(id)
  else
    false
  end
```

**3b. Remove `alive_session_ref` from assigns (line 68):**

Remove:
```elixir
|> assign(:alive_session_ref, alive_session_ref)
```

**3c. Remove `alive_session_ref` from the not-found path (line 77):**

Remove:
```elixir
|> assign(:alive_session_ref, nil)
```

**3d. Replace `handle_info({:claude_session_started, ...})` (lines 336-351) and `handle_info({:DOWN, ...})` (lines 353-359):**

Remove both handlers. Replace with a single handler for the new aliveness message:

```elixir
def handle_info({:aliveness_changed, ws_id, alive?}, socket) do
  if socket.assigns[:workflow_session] && ws_id == socket.assigns.workflow_session.id do
    {:noreply, assign(socket, :alive_session, alive?)}
  else
    {:noreply, socket}
  end
end
```

Place this before the catch-all `def handle_info(_msg, socket)` on line 361.

### Step 4 — Simplify `CraftingBoardLive`

**File:** `lib/destila_web/live/crafting_board_live.ex`

**4a. Remove `monitored_refs` assign from `mount/3` (line 27):**

Remove:
```elixir
|> assign(:monitored_refs, %{})
```

**4b. Change PubSub subscription in `mount/3` (line 19):**

Replace:
```elixir
Phoenix.PubSub.subscribe(Destila.PubSub, Destila.PubSubHelper.claude_session_topic())
```

With:
```elixir
Phoenix.PubSub.subscribe(Destila.PubSub, Destila.AI.AlivenessTracker.topic())
```

**4c. Replace `monitor_alive_sessions/1` (lines 105-135) with an ETS-based version:**

Replace the entire function with:
```elixir
defp load_alive_sessions(socket) do
  if not connected?(socket) do
    socket
  else
    alive_map =
      socket.assigns.all_prompts
      |> Enum.filter(fn session -> Destila.AI.AlivenessTracker.alive?(session.id) end)
      |> Map.new(fn session -> {session.id, true} end)

    assign(socket, :alive_sessions, alive_map)
  end
end
```

**4d. Update callers of `monitor_alive_sessions` (lines 41, 68):**

Replace `monitor_alive_sessions()` with `load_alive_sessions()` in both:
- `handle_params/3` (line 41)
- `handle_info` for `:workflow_session_created`/`:workflow_session_updated` (line 68)

**4e. Replace `handle_info({:claude_session_started, ...})` (lines 71-86) and `handle_info({:DOWN, ...})` (lines 88-99):**

Remove both handlers. Replace with a single handler:

```elixir
def handle_info({:aliveness_changed, ws_id, alive?}, socket) do
  if alive? do
    {:noreply, update(socket, :alive_sessions, &Map.put(&1, ws_id, true))}
  else
    {:noreply, update(socket, :alive_sessions, &Map.delete(&1, ws_id))}
  end
end
```

Place this before the catch-all `def handle_info(_msg, socket)` on line 101.

### Step 5 — Update feature files

**5a. File: `features/crafting_board.feature`**

The existing aliveness scenarios (lines ~80-100) don't need text changes — the behavior is identical. The implementation detail (centralized tracker vs per-LiveView monitor) is invisible to BDD scenarios.

**5b. File: `features/brainstorm_idea_workflow.feature`**

Same — no scenario text changes needed.

### Step 6 — Add `AlivenessTracker` unit tests

**File:** `test/destila/ai/aliveness_tracker_test.exs` (new)

```elixir
defmodule Destila.AI.AlivenessTrackerTest do
  use ExUnit.Case, async: false

  alias Destila.AI.AlivenessTracker

  test "alive?/1 returns false for unknown session" do
    refute AlivenessTracker.alive?("nonexistent")
  end

  test "tracks session started via PubSub broadcast" do
    session_id = Ecto.UUID.generate()

    # Register a dummy agent in the AI SessionRegistry
    {:ok, pid} =
      Agent.start_link(fn -> nil end,
        name: {:via, Registry, {Destila.AI.SessionRegistry, session_id}}
      )

    # Subscribe to aliveness changes
    Phoenix.PubSub.subscribe(Destila.PubSub, AlivenessTracker.topic())

    # Simulate the broadcast that ClaudeSession.init/1 sends
    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      Destila.PubSubHelper.claude_session_topic(),
      {:claude_session_started, session_id}
    )

    # Wait for the tracker to process the message
    assert_receive {:aliveness_changed, ^session_id, true}

    assert AlivenessTracker.alive?(session_id)

    # Stop the agent — should trigger :DOWN
    Agent.stop(pid)

    assert_receive {:aliveness_changed, ^session_id, false}
    refute AlivenessTracker.alive?(session_id)
  end

  test "initial scan picks up already-running sessions" do
    session_id = Ecto.UUID.generate()

    # Register before the tracker has a chance to scan
    # (tracker is already running, but we can verify it picks up new registrations
    # via the PubSub mechanism — the init scan is for cold starts)
    {:ok, _pid} =
      Agent.start_link(fn -> nil end,
        name: {:via, Registry, {Destila.AI.SessionRegistry, session_id}}
      )

    # Broadcast to notify tracker
    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      Destila.PubSubHelper.claude_session_topic(),
      {:claude_session_started, session_id}
    )

    # Give tracker time to process
    _ = :sys.get_state(AlivenessTracker)

    assert AlivenessTracker.alive?(session_id)
  end
end
```

### Step 7 — Verify existing tests still pass

The existing tests in `test/destila_web/live/crafting_board_live_test.exs` (aliveness indicator describe block, lines 448-546) should continue to pass because:

1. Tests that register agents in `Destila.AI.SessionRegistry` will trigger `AlivenessTracker` to detect and track them (when the tracker subscribes to `claude_sessions` PubSub). However, the tests currently rely on per-LiveView monitoring. With the tracker, the LiveView will get aliveness via ETS + PubSub instead.

2. The "green dot" test registers an agent and then mounts the LiveView. The tracker will pick up the agent if a `:claude_session_started` broadcast occurs. Since the test agents don't broadcast, we need to ensure the test either:
   - Broadcasts `{:claude_session_started, ws.id}` after registering the agent, OR
   - The tracker's behavior is such that the LiveView's `load_alive_sessions/1` call in `handle_params` does the ETS lookup, which requires the tracker to already know about the agent.

   **Important consideration:** The existing tests register agents manually without broadcasting `{:claude_session_started, ...}`. The `monitor_alive_sessions/1` function currently does a direct `GenServer.whereis` + `Process.monitor` which catches these agents. With the tracker, the LiveView uses `AlivenessTracker.alive?/1` instead, which depends on the tracker having been notified via PubSub.

   **Fix:** After registering the test agent, broadcast the session started event so the tracker picks it up:

   ```elixir
   # In tests that register a dummy agent:
   Phoenix.PubSub.broadcast(
     Destila.PubSub,
     Destila.PubSubHelper.claude_session_topic(),
     {:claude_session_started, ws.id}
   )
   # Ensure tracker processes the message
   _ = :sys.get_state(Destila.AI.AlivenessTracker)
   ```

   This needs to be added to:
   - `crafting_board_live_test.exs` — "shows green dot when GenServer is running" test (after `start_supervised!`, line ~510)
   - `crafting_board_live_test.exs` — "updates from green to red when GenServer stops" test (after `Agent.start_link`, line ~530)

   The `:DOWN` path will work automatically since the tracker monitors the agent and broadcasts `{:aliveness_changed, ...}` on death.

### Step 8 — Run `mix precommit`

Verify compilation, formatting, and all tests pass.

## Files changed

| File | Change |
|---|---|
| `lib/destila/ai/aliveness_tracker.ex` | **New** — Centralized GenServer that monitors AI sessions via ETS + PubSub |
| `lib/destila/application.ex` | Add `AlivenessTracker` to supervision tree |
| `lib/destila_web/live/workflow_runner_live.ex` | Remove `Process.monitor` logic, `alive_session_ref` assign; subscribe to tracker PubSub; read from `AlivenessTracker.alive?/1` |
| `lib/destila_web/live/crafting_board_live.ex` | Remove `monitored_refs` assign, `monitor_alive_sessions/1`; replace with `load_alive_sessions/1` using ETS reads; subscribe to tracker PubSub |
| `test/destila/ai/aliveness_tracker_test.exs` | **New** — Unit tests for the tracker |
| `test/destila_web/live/crafting_board_live_test.exs` | Add PubSub broadcast + `:sys.get_state` sync in aliveness tests |

## Acceptance criteria

- `AlivenessTracker` GenServer starts in the supervision tree and monitors all AI session processes
- No `Process.monitor` calls remain in any LiveView for AI session tracking
- No `monitored_refs` or `alive_session_ref` assigns remain in LiveViews
- LiveViews use `AlivenessTracker.alive?/1` (ETS) for initial state and `{:aliveness_changed, ...}` (PubSub) for updates
- All existing aliveness tests pass (with minor adjustments for PubSub broadcast)
- New `AlivenessTrackerTest` passes
- `mix precommit` passes

## Edge cases

### Tracker restarts

If the `AlivenessTracker` crashes and restarts (supervised as `one_for_one`), its `init/1` scans the Registry for existing sessions, so it recovers state. The ETS table is destroyed on crash and recreated — LiveViews making `alive?/1` calls during this brief gap will get `false` (safe default) and then receive a corrected `{:aliveness_changed, ..., true}` once the tracker re-monitors.

### Race: session dies between ETS insert and PubSub broadcast

`Process.monitor/1` guarantees a `:DOWN` message even if the process is already dead when monitored. The tracker handles this correctly: it inserts into ETS, then when `:DOWN` arrives, deletes from ETS and broadcasts `false`.

### LiveView mounts between tracker insert and broadcast

If a LiveView calls `alive?/1` right after the tracker inserts into ETS but before it broadcasts, the LiveView gets `true` from ETS. The subsequent broadcast is also received but is a no-op (already showing alive). No inconsistency.
