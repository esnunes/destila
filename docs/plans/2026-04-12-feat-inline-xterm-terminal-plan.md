# Feature: Inline xterm.js Terminal in Workflow Runner

Replace the "Open Terminal" button (which launches an external Ghostty window) with an embedded terminal inside the workflow runner UI using [xterm.js](https://xtermjs.org/). The terminal runs in a collapsible panel below the main chat content, connected to a real shell session at the worktree path via a Phoenix Channel and the `expty` library for PTY management.

## Architecture overview

```
Browser (xterm.js)  ──WebSocket──▶  Phoenix Channel  ──▶  GenServer (TerminalServer)  ──▶  ExPTY (PTY process)
      ▲                                    │                          │
      └────── push "output" ◀──────────────┘                          │
              push "input"  ──────────────▶ write to PTY ─────────────┘
              push "resize" ──────────────▶ resize PTY ───────────────┘
```

- **xterm.js** renders the terminal in the browser and captures keystrokes
- **Phoenix Channel** (`TerminalChannel`) bridges WebSocket messages between browser and server
- **GenServer** (`Terminal.Server`) owns the ExPTY process, forwards I/O, handles lifecycle
- **DynamicSupervisor** (`Terminal.Supervisor`) supervises per-session terminal servers
- **LiveView** (`WorkflowRunnerLive`) renders the terminal panel and coordinates open/close via LiveView events; the xterm.js hook connects its own channel independently

## Dependencies

### New Elixir dependency

Add to `mix.exs`:

```elixir
{:expty, "~> 0.2"}
```

ExPTY provides `forkpty(3)` bindings — it spawns a real PTY process (not a dumb pipe), so the shell behaves like a real terminal with job control, colors, and cursor movement.

### New npm dependency

Install in the `assets/` directory:

```bash
cd assets && npm install @xterm/xterm @xterm/addon-fit
```

- `@xterm/xterm` — terminal emulator component
- `@xterm/addon-fit` — auto-fits terminal to container dimensions

Since the project uses esbuild (not node_modules by default), these must be installed via npm in the assets directory and imported. The existing esbuild config has `NODE_PATH` pointing to `deps/` but npm packages go to `assets/node_modules/`. Add `assets/node_modules` to `NODE_PATH` in the esbuild config.

## Step 1 — Add expty dependency and update esbuild config

### 1a. `mix.exs` — add expty

```elixir
{:expty, "~> 0.2"}
```

Run `mix deps.get` after.

### 1b. `config/config.exs` — update esbuild NODE_PATH

Update the esbuild config to include `assets/node_modules` so npm packages are resolvable:

```elixir
config :esbuild,
  version: "0.25.4",
  destila: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{
      "NODE_PATH" =>
        Enum.join(
          [
            Path.expand("../assets/node_modules", __DIR__),
            Path.expand("../deps", __DIR__),
            Mix.Project.build_path()
          ],
          ":"
        )
    }
  ]
```

### 1c. Install npm packages

```bash
cd assets && npm install @xterm/xterm @xterm/addon-fit
```

Add `assets/node_modules` and `assets/package-lock.json` to `.gitignore` if not already there. Add `assets/package.json` to version control.

## Step 2 — Terminal server (GenServer wrapping ExPTY)

**New file:** `lib/destila/terminal/server.ex`

```elixir
defmodule Destila.Terminal.Server do
  use GenServer

  defstruct [:pty, :topic, :cols, :rows]

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def write(server, data), do: GenServer.cast(server, {:write, data})
  def resize(server, cols, rows), do: GenServer.cast(server, {:resize, cols, rows})
  def stop(server), do: GenServer.stop(server, :normal)

  @impl true
  def init(opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    topic = Keyword.fetch!(opts, :topic)
    cols = Keyword.get(opts, :cols, 80)
    rows = Keyword.get(opts, :rows, 24)
    shell = System.get_env("SHELL", "/bin/sh")

    {:ok, pty} =
      ExPTY.spawn(shell, ["-l"], cwd: cwd, cols: cols, rows: rows, env: System.get_env())

    ExPTY.on_data(pty, fn _pty, _pid, data ->
      Phoenix.PubSub.broadcast(Destila.PubSub, topic, {:terminal_output, data})
    end)

    ExPTY.on_exit(pty, fn _pty, _exit_code, _signal ->
      Phoenix.PubSub.broadcast(Destila.PubSub, topic, :terminal_exited)
    end)

    {:ok, %__MODULE__{pty: pty, topic: topic, cols: cols, rows: rows}}
  end

  @impl true
  def handle_cast({:write, data}, state) do
    ExPTY.write(state.pty, data)
    {:noreply, state}
  end

  def handle_cast({:resize, cols, rows}, state) do
    ExPTY.resize(state.pty, cols, rows)
    {:noreply, %{state | cols: cols, rows: rows}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.pty, do: ExPTY.kill(state.pty, 15)
    :ok
  end
end
```

Key decisions:
- Uses PubSub to broadcast output — the channel subscribes to the topic and forwards to the client
- Spawns a login shell (`-l` flag) so the user's profile is loaded
- Passes the full system environment so tools like `git`, `mix`, `claude` are available
- On terminate, sends SIGTERM to the PTY process

### Binary data encoding

ExPTY's `on_data` callback delivers raw binary data. Terminal output is almost always valid UTF-8 (text + ANSI escape sequences), but edge cases (e.g., `cat` on a binary file) can produce invalid bytes. Phoenix Channel's `push/3` encodes payloads as JSON, which requires valid UTF-8 strings.

To handle this safely, Base64-encode the data in the channel push and decode on the client:

**Server (TerminalChannel):**
```elixir
def handle_info({:terminal_output, data}, socket) do
  push(socket, "output", %{data: Base64.encode(data)})
  {:noreply, socket}
end
```

**Client (terminal_panel.js):**
```javascript
this.channel.on("output", ({ data }) => {
  const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0))
  this.term.write(bytes)
})
```

xterm.js's `write()` accepts both strings and `Uint8Array`, so passing raw bytes avoids any encoding issues.

## Step 3 — Terminal supervisor

**New file:** `lib/destila/terminal/supervisor.ex`

```elixir
defmodule Destila.Terminal.Supervisor do
  @moduledoc "DynamicSupervisor for per-session terminal server processes."

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {DynamicSupervisor, :start_link, [[name: __MODULE__, strategy: :one_for_one]]},
      type: :supervisor
    }
  end

  def start_terminal(session_id, cwd, opts \\ []) do
    topic = "terminal:#{session_id}"
    name = {:via, Registry, {Destila.Terminal.Registry, session_id}}

    child_opts =
      Keyword.merge(opts, name: name, cwd: cwd, topic: topic)

    DynamicSupervisor.start_child(__MODULE__, {Destila.Terminal.Server, child_opts})
  end

  def stop_terminal(session_id) do
    case Registry.lookup(Destila.Terminal.Registry, session_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  def terminal_running?(session_id) do
    Registry.lookup(Destila.Terminal.Registry, session_id) != []
  end

  def get_terminal(session_id) do
    case Registry.lookup(Destila.Terminal.Registry, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end
end
```

**Update `lib/destila/application.ex`** — add Registry and Supervisor to children list (before `DestilaWeb.Endpoint`):

```elixir
{Registry, keys: :unique, name: Destila.Terminal.Registry},
Destila.Terminal.Supervisor,
```

## Step 4 — Phoenix Channel for terminal I/O

**New file:** `lib/destila_web/channels/terminal_channel.ex`

```elixir
defmodule DestilaWeb.TerminalChannel do
  use DestilaWeb, :channel

  alias Destila.Terminal.Supervisor, as: TermSup

  @impl true
  def join("terminal:" <> session_id, _params, socket) do
    topic = "terminal:#{session_id}"
    Phoenix.PubSub.subscribe(Destila.PubSub, topic)

    {:ok, assign(socket, :session_id, session_id)}
  end

  @impl true
  def handle_in("input", %{"data" => data}, socket) do
    case TermSup.get_terminal(socket.assigns.session_id) do
      {:ok, pid} -> Destila.Terminal.Server.write(pid, data)
      :error -> :ok
    end

    {:noreply, socket}
  end

  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket) do
    case TermSup.get_terminal(socket.assigns.session_id) do
      {:ok, pid} -> Destila.Terminal.Server.resize(pid, cols, rows)
      :error -> :ok
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:terminal_output, data}, socket) do
    push(socket, "output", %{data: Base.encode64(data)})
    {:noreply, socket}
  end

  def handle_info(:terminal_exited, socket) do
    push(socket, "exited", %{})
    {:noreply, socket}
  end
end
```

**New file:** `lib/destila_web/channels/terminal_socket.ex`

```elixir
defmodule DestilaWeb.TerminalSocket do
  use Phoenix.Socket

  channel "terminal:*", DestilaWeb.TerminalChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
```

**Update `lib/destila_web/endpoint.ex`** — add the terminal socket (after the LiveView socket):

```elixir
socket "/terminal", DestilaWeb.TerminalSocket,
  websocket: true,
  longpoll: false
```

## Step 5 — xterm.js hook (external JS hook)

The terminal hook must be an **external hook** (not colocated) because it imports npm packages (`@xterm/xterm`, `@xterm/addon-fit`). Colocated hooks (`.DotPrefix` style) are compiled inline by Phoenix and may not resolve npm imports through esbuild. External hooks live in `assets/js/` and are registered in `app.js` — this is the same pattern used by `ScrollBottomHook` and `AutoDismissHook` in the existing codebase.

**New file:** `assets/js/hooks/terminal_panel.js`

The hook:
1. Creates the xterm.js Terminal instance with theme-aware colors
2. Connects to the Phoenix Channel for the session (separate WebSocket from LiveView)
3. Pipes keystrokes → channel → server → PTY
4. Pipes PTY output (Base64-decoded) → xterm.js
5. Handles resize events via the FitAddon + ResizeObserver

```javascript
import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import { Socket } from "phoenix"

const DARK_THEME = {
  background: "#1a1a2e",
  foreground: "#e0e0e0",
  cursor: "#a0a0ff",
  selectionBackground: "rgba(255, 255, 255, 0.15)",
}

const LIGHT_THEME = {
  background: "#fafafa",
  foreground: "#1a1a2e",
  cursor: "#5555dd",
  selectionBackground: "rgba(0, 0, 0, 0.12)",
}

function currentTheme() {
  const attr = document.documentElement.getAttribute("data-theme")
  if (attr === "light") return LIGHT_THEME
  if (attr === "dark") return DARK_THEME
  // "system" / no attribute — check prefers-color-scheme
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? DARK_THEME : LIGHT_THEME
}

export default {
  mounted() {
    const sessionId = this.el.dataset.sessionId
    const container = this.el.querySelector("[data-terminal-container]")
    const theme = currentTheme()

    // Create xterm.js instance
    this.term = new Terminal({
      cursorBlink: true,
      fontSize: 13,
      fontFamily: "'SF Mono', 'Menlo', 'Monaco', 'Courier New', monospace",
      theme,
    })

    this.fitAddon = new FitAddon()
    this.term.loadAddon(this.fitAddon)
    this.term.open(container)

    // Delay first fit() to ensure the container has a layout size
    requestAnimationFrame(() => this.fitAddon.fit())

    // Connect to Phoenix Channel (separate socket from LiveView)
    const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
    this.socket = new Socket("/terminal", { params: { _csrf_token: csrfToken } })
    this.socket.connect()
    this.channel = this.socket.channel(`terminal:${sessionId}`, {})

    this.channel.join()
      .receive("ok", () => {
        // Send initial resize after layout is stable
        requestAnimationFrame(() => {
          this.fitAddon.fit()
          const dims = this.fitAddon.proposeDimensions()
          if (dims) {
            this.channel.push("resize", { cols: dims.cols, rows: dims.rows })
          }
        })
      })
      .receive("error", (resp) => {
        this.term.write(`\r\n\x1b[31mFailed to connect: ${JSON.stringify(resp)}\x1b[0m\r\n`)
      })

    // Terminal input → channel
    this.term.onData((data) => {
      this.channel.push("input", { data })
    })

    // Channel output → terminal (Base64-decoded to handle binary data safely)
    this.channel.on("output", ({ data }) => {
      const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0))
      this.term.write(bytes)
    })

    // Shell process exited — notify LiveView
    this.channel.on("exited", () => {
      this.term.write("\r\n\x1b[90m[Process exited]\x1b[0m\r\n")
      this.pushEvent("terminal_exited", {})
    })

    // Handle container resize → re-fit terminal and notify server of new dimensions
    this.resizeObserver = new ResizeObserver(() => {
      this.fitAddon.fit()
      const dims = this.fitAddon.proposeDimensions()
      if (dims && this.channel) {
        this.channel.push("resize", { cols: dims.cols, rows: dims.rows })
      }
    })
    this.resizeObserver.observe(container)

    // Listen for theme changes (the app dispatches "phx:set-theme" and "phx:cycle-theme")
    this._themeListener = () => {
      // Small delay to let the data-theme attribute update first
      setTimeout(() => this.term.options.theme = currentTheme(), 50)
    }
    window.addEventListener("phx:set-theme", this._themeListener)
    window.addEventListener("phx:cycle-theme", this._themeListener)
  },

  destroyed() {
    // Clean up all resources. Do NOT pushEvent here — the element is already
    // being removed from the DOM (triggered by the LiveView setting terminal_open=false),
    // so pushEvent is unreliable and the server already knows the terminal is closing.
    if (this._themeListener) {
      window.removeEventListener("phx:set-theme", this._themeListener)
      window.removeEventListener("phx:cycle-theme", this._themeListener)
    }
    if (this.resizeObserver) this.resizeObserver.disconnect()
    if (this.channel) this.channel.leave()
    if (this.socket) this.socket.disconnect()
    if (this.term) this.term.dispose()
  }
}
```

### Register the hook in app.js

**File:** `assets/js/app.js` — add import at top and register in the Hooks object.

After the existing imports (line 26: `import topbar from "../vendor/topbar"`), add:

```javascript
import TerminalPanel from "./hooks/terminal_panel"
```

Update the Hooks object (currently lines 56–61):

```javascript
const Hooks = {
  ...colocatedHooks,
  ScrollBottom: ScrollBottomHook,
  FocusFirstError: FocusFirstErrorHook,
  AutoDismiss: AutoDismissHook,
  TerminalPanel: TerminalPanel,
}
```

The hook uses `phx-hook="TerminalPanel"` (no dot prefix) since it's an external hook.

## Step 6 — LiveView changes (WorkflowRunnerLive)

### 6a. New assigns in `mount_session/2`

**File:** `lib/destila_web/live/workflow_runner_live.ex`

Add after the existing modal assigns. Insert after line 70 (`|> assign(:text_modal_label, nil)`), before line 71 (`|> assign(:phase_status, ...)`):

```elixir
|> assign(:terminal_open, false)
```

On mount, check if a terminal server is already running for this session (handles page refresh / reconnect):

```elixir
|> assign(:terminal_open, Destila.Terminal.Supervisor.terminal_running?(workflow_session.id))
```

This ensures that if the user refreshes the page while a terminal is running, the panel reappears automatically.

### 6b. Replace "open_terminal" event handler

**File:** `lib/destila_web/live/workflow_runner_live.ex`

Remove the `alias Destila.DevTools` line (line 21). Replace the current handler (lines 370–382):

```elixir
# Current code to remove:
def handle_event("open_terminal", _params, socket) do
  case DevTools.open_terminal(
         socket.assigns.workflow_session.title,
         socket.assigns.worktree_path,
         socket.assigns.claude_session_id
       ) do
    :ok ->
      {:noreply, socket}

    {:error, reason} ->
      {:noreply, put_flash(socket, :error, "Could not open Ghostty: #{reason}")}
  end
end
```

Replace with:

```elixir
def handle_event("open_terminal", _params, socket) do
  ws = socket.assigns.workflow_session
  cwd = socket.assigns.worktree_path

  case Destila.Terminal.Supervisor.start_terminal(ws.id, cwd) do
    {:ok, _pid} ->
      {:noreply, assign(socket, :terminal_open, true)}

    {:error, {:already_started, _pid}} ->
      {:noreply, assign(socket, :terminal_open, true)}

    {:error, reason} ->
      {:noreply, put_flash(socket, :error, "Could not start terminal: #{inspect(reason)}")}
  end
end

def handle_event("close_terminal", _params, socket) do
  Destila.Terminal.Supervisor.stop_terminal(socket.assigns.workflow_session.id)
  {:noreply, assign(socket, :terminal_open, false)}
end

def handle_event("terminal_exited", _params, socket) do
  Destila.Terminal.Supervisor.stop_terminal(socket.assigns.workflow_session.id)
  {:noreply, assign(socket, :terminal_open, false)}
end
```

### 6c. Clean up terminal on LiveView terminate

Add a `terminate/2` callback so the terminal server is stopped when the user navigates away from the session page:

```elixir
@impl true
def terminate(_reason, socket) do
  if socket.assigns[:workflow_session] do
    Destila.Terminal.Supervisor.stop_terminal(socket.assigns.workflow_session.id)
  end

  :ok
end
```

This prevents orphaned terminal processes when users navigate away without explicitly closing the terminal panel.

### 6d. Update render template — sidebar button

**File:** `lib/destila_web/live/workflow_runner_live.ex` — lines 701–726 (source code section)

Replace the "Source code section" block with a version where the button toggles the terminal:

```heex
<%!-- Source code section --%>
<div
  :if={@worktree_path}
  class="p-4 border-b border-base-300/60"
>
  <div class="flex items-center gap-2 mb-3">
    <.icon
      name="hero-folder-open-micro"
      class="size-4 text-base-content/30"
    />
    <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wide flex-1">
      Source Code
    </h3>
    <button
      id="open-terminal-btn"
      phx-click={if(@terminal_open, do: "close_terminal", else: "open_terminal")}
      class={[
        "p-1 rounded-md transition-colors text-[0px]",
        if(@terminal_open,
          do: "bg-primary/10 text-primary hover:bg-primary/20",
          else: "hover:bg-base-300/50 text-primary"
        )
      ]}
      aria-label={if(@terminal_open, do: "Close terminal", else: "Open terminal")}
    >
      <.icon name="hero-command-line-micro" class="size-4" />
    </button>
  </div>
  <code class="text-xs text-base-content/50 break-all leading-relaxed">
    {@worktree_path}
  </code>
</div>
```

### 6e. Update render template — terminal panel in main content area

**File:** `lib/destila_web/live/workflow_runner_live.ex` — lines 631–636 (the `flex flex-row` container)

The current layout wraps the phase content and sidebar in a horizontal flex container:

```heex
<%!-- Current (lines 631–636): --%>
<div class="flex flex-row flex-1 min-h-0">
  <%!-- Phase content — takes remaining space --%>
  <div class="flex-1 min-h-0 overflow-hidden">
    {render_phase(assigns)}
  </div>
  <%!-- Exported metadata sidebar --%>
  ...
```

Wrap the phase content div in a vertical flex column so the terminal panel can stack below it:

```heex
<%!-- Phase content + sidebar — full remaining height --%>
<div class="flex flex-row flex-1 min-h-0">
  <%!-- Phase content + terminal stack --%>
  <div class="flex flex-col flex-1 min-h-0">
    <%!-- Phase content — takes remaining space --%>
    <div class="flex-1 min-h-0 overflow-hidden">
      {render_phase(assigns)}
    </div>

    <%!-- Terminal panel --%>
    <div
      :if={@terminal_open && @worktree_path}
      id={"terminal-panel-#{@workflow_session.id}"}
      phx-hook="TerminalPanel"
      phx-update="ignore"
      data-session-id={@workflow_session.id}
      class="border-t border-base-300 bg-base-200 flex flex-col shrink-0"
      style="height: 300px; min-height: 200px;"
    >
      <%!-- Terminal header bar --%>
      <div class="flex items-center justify-between px-3 py-1.5 bg-base-300/30 border-b border-base-300/40">
        <div class="flex items-center gap-2">
          <.icon name="hero-command-line-micro" class="size-3.5 text-base-content/40" />
          <span class="text-xs text-base-content/40 font-medium">Terminal</span>
        </div>
        <button
          phx-click="close_terminal"
          class="p-0.5 rounded hover:bg-base-300/50 transition-colors"
          aria-label="Close terminal"
        >
          <.icon name="hero-x-mark-micro" class="size-3.5 text-base-content/40" />
        </button>
      </div>
      <%!-- xterm.js container — background set by xterm.js theme, not CSS --%>
      <div data-terminal-container class="flex-1 overflow-hidden" />
    </div>
  </div>

  <%!-- Exported metadata sidebar --%>
  ...
</div>
```

Key decisions:
- `phx-update="ignore"` prevents LiveView from touching the DOM managed by xterm.js
- `phx-hook="TerminalPanel"` is an external hook (no dot prefix) since it imports npm packages
- The terminal panel has a fixed height of 300px with `shrink-0` so it doesn't compress
- The panel container uses `bg-base-200` (neutral) — xterm.js overrides the actual terminal background via its theme config, which adapts to dark/light mode (see Step 5 hook)
- The close button inside `phx-update="ignore"` works because `phx-click` bindings are attached at mount time and persist
- The `phx-click="close_terminal"` event tells the LiveView to set `terminal_open=false`, which removes the panel via `:if`, which triggers the hook's `destroyed()` for cleanup

## Step 7 — xterm.js CSS

The xterm.js library requires its CSS to be loaded. Since the project uses Tailwind CLI for CSS processing (not esbuild), copy the xterm CSS into the vendor directory:

```bash
cp assets/node_modules/@xterm/xterm/css/xterm.css assets/vendor/xterm.css
```

Then import it in `assets/css/app.css` (after the Tailwind imports):

```css
@import "../vendor/xterm.css";
```

## Step 8 — Update feature file

**File:** `features/exported_metadata.feature`

Update the two terminal-related scenarios:

```gherkin
  # --- Source Code Terminal ---

  Scenario: Source code section shows terminal toggle button
    Given I am on a session detail page
    And the session has a worktree path
    Then the source code section should display a terminal toggle button

  Scenario: Terminal toggle opens an inline xterm.js terminal
    Given I am on a session detail page
    And the session has a worktree path
    When I click the terminal toggle button
    Then an inline terminal panel should appear below the chat area
    And the terminal should be connected to a shell at the worktree path

  Scenario: Terminal toggle closes the inline terminal
    Given I am on a session detail page
    And the session has an open inline terminal
    When I click the terminal toggle button again
    Then the terminal panel should close
    And the terminal process should be stopped
```

## Step 9 — Update tests

**File:** `test/destila_web/live/open_terminal_live_test.exs`

Update the existing tests:

```elixir
defmodule DestilaWeb.OpenTerminalLiveTest do
  @moduledoc """
  LiveView tests for inline terminal panel in sidebar.
  Feature: features/exported_metadata.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    ClaudeCode.Test.set_mode_to_shared()

    ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
      [
        ClaudeCode.Test.text("AI response"),
        ClaudeCode.Test.result("AI response")
      ]
    end)

    {:ok, conn: conn}
  end

  defp create_session_with_worktree(conn) do
    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test Session",
        workflow_type: :brainstorm_idea,
        project_id: nil,
        done_at: DateTime.utc_now(),
        current_phase: 4,
        total_phases: 4
      })

    {:ok, _ai_session} =
      Destila.AI.create_ai_session(%{
        workflow_session_id: ws.id,
        worktree_path: "/tmp/test-worktree"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")
    {ws, view}
  end

  describe "terminal toggle button" do
    @tag feature: "exported_metadata",
         scenario: "Source code section shows terminal toggle button"
    test "button is present when worktree path exists", %{conn: conn} do
      {_ws, view} = create_session_with_worktree(conn)

      assert has_element?(view, "#open-terminal-btn")
    end

    @tag feature: "exported_metadata",
         scenario: "Terminal toggle opens an inline xterm.js terminal"
    test "clicking the button opens the terminal panel", %{conn: conn} do
      {ws, view} = create_session_with_worktree(conn)

      view |> element("#open-terminal-btn") |> render_click()

      assert has_element?(view, "#terminal-panel-#{ws.id}")
    end

    @tag feature: "exported_metadata",
         scenario: "Terminal toggle closes the inline terminal"
    test "clicking the button again closes the terminal panel", %{conn: conn} do
      {ws, view} = create_session_with_worktree(conn)

      # Open
      view |> element("#open-terminal-btn") |> render_click()
      assert has_element?(view, "#terminal-panel-#{ws.id}")

      # Close
      view |> element("#open-terminal-btn") |> render_click()
      refute has_element?(view, "#terminal-panel-#{ws.id}")
    end
  end
end
```

**New file:** `test/destila/terminal/server_test.exs`

```elixir
defmodule Destila.Terminal.ServerTest do
  use ExUnit.Case, async: true

  alias Destila.Terminal.Server

  @tag :terminal
  test "starts and stops a terminal server" do
    topic = "terminal:test-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Destila.PubSub, topic)

    {:ok, pid} =
      start_supervised(
        {Server, name: {:global, topic}, cwd: System.tmp_dir!(), topic: topic}
      )

    # The shell should produce some output (prompt)
    assert_receive {:terminal_output, _data}, 5_000

    # Write a command
    Server.write(pid, "echo hello\n")
    assert_receive {:terminal_output, _data}, 5_000

    # Stop
    stop_supervised(Server)
  end
end
```

## Files changed

| File | Change |
|---|---|
| `mix.exs` | Add `{:expty, "~> 0.2"}` dependency |
| `config/config.exs` | Update esbuild NODE_PATH to include `assets/node_modules` |
| `assets/package.json` | New — npm dependencies for xterm.js |
| `assets/vendor/xterm.css` | New — vendored xterm.js CSS |
| `assets/css/app.css` | Import xterm.css |
| `assets/js/hooks/terminal_panel.js` | New — xterm.js LiveView hook |
| `assets/js/app.js` | Import and register TerminalPanel hook |
| `lib/destila/terminal/server.ex` | New — GenServer wrapping ExPTY |
| `lib/destila/terminal/supervisor.ex` | New — DynamicSupervisor for terminal servers |
| `lib/destila/application.ex` | Add Terminal.Registry and Terminal.Supervisor to children |
| `lib/destila_web/channels/terminal_channel.ex` | New — Phoenix Channel for terminal I/O |
| `lib/destila_web/channels/terminal_socket.ex` | New — Phoenix Socket for terminal channels |
| `lib/destila_web/endpoint.ex` | Add terminal socket mount |
| `lib/destila_web/live/workflow_runner_live.ex` | Replace Ghostty handler with terminal panel; add assigns, events, template |
| `features/exported_metadata.feature` | Update terminal-related scenarios |
| `test/destila_web/live/open_terminal_live_test.exs` | Update tests for inline terminal |
| `test/destila/terminal/server_test.exs` | New — Terminal.Server unit tests |

## Design decisions

1. **Phoenix Channel (not LiveView push_event)** — Terminal I/O is high-frequency binary data. Channels provide a dedicated WebSocket path with lower overhead than routing everything through the LiveView socket. The LiveView controls the panel visibility; the channel handles raw I/O independently. The hook creates its own `Socket("/terminal", ...)` — this is a separate WebSocket connection from the LiveView socket at `/live`.

2. **External hook (not colocated)** — The terminal hook imports `@xterm/xterm` and `@xterm/addon-fit` from npm. Colocated hooks (`.DotPrefix` style) are compiled inline by Phoenix and cannot reliably resolve npm imports through the esbuild pipeline. An external hook in `assets/js/hooks/` is the correct approach for hooks with third-party dependencies.

3. **ExPTY (not Erlang Port)** — Erlang's `Port.open/2` does not allocate a PTY, so programs that check `isatty()` (like shells, git, less) run in "dumb" mode without colors or line editing. ExPTY uses `forkpty(3)` to give the process a real terminal.

4. **DynamicSupervisor + Registry** — Follows the existing codebase pattern (`Destila.Sessions.Supervisor`, `Destila.AI.SessionSupervisor`). One terminal per session, looked up by session ID via the Registry.

5. **Fixed-height panel (not resizable)** — A drag-to-resize handle adds significant complexity. Start with a fixed 300px height. Resizability can be added later as an enhancement.

6. **Terminal panel below chat (not in sidebar)** — The sidebar is 320px wide and reserved for metadata. The terminal needs horizontal space for an 80-column display. Placing it below the chat in the main content area gives it full width.

7. **Vendored xterm.css** — The project's CSS pipeline uses Tailwind CLI, not esbuild. Vendoring the CSS file (like topbar.js, daisyui.js) is consistent with the project pattern and avoids npm import resolution issues in the CSS pipeline.

8. **Base64 encoding for terminal output** — ExPTY's `on_data` callback delivers raw binary data. While terminal output is usually valid UTF-8 (text + ANSI escapes), edge cases like `cat`-ing a binary file produce invalid UTF-8 bytes that would break JSON encoding in the channel push. Base64 encoding the data server-side and decoding client-side (passing `Uint8Array` to `xterm.write()`) handles all byte sequences safely.

9. **Theme-aware terminal colors** — The app supports light, dark, and system theme modes (via `data-theme` attribute on `<html>`). The hook reads the current theme on mount and listens for `phx:set-theme` / `phx:cycle-theme` events to update xterm.js colors dynamically. The panel container uses `bg-base-200` as a neutral fallback; xterm.js overrides the terminal viewport background.

10. **Terminal lifecycle: reconnect and cleanup** — On mount, the LiveView checks `Terminal.Supervisor.terminal_running?/1` to recover from page refreshes. On `terminate/2`, the LiveView stops the terminal server to prevent orphaned PTY processes. The hook's `destroyed()` only does client-side cleanup (dispose xterm, disconnect channel) — it does NOT push events back to the server, since the LiveView already knows the terminal is closing (it triggered the removal via `terminal_open=false`).
