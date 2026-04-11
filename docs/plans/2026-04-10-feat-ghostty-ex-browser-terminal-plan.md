# Feature: In-Browser Terminal via ghostty_ex

Replace the current "Open Terminal" button (which launches the Ghostty desktop app via `System.cmd`) with an in-browser terminal powered by the [`ghostty_ex`](https://github.com/dannote/ghostty_ex) library. Clicking the button opens a new browser tab containing a fully interactive terminal at the session's worktree path.

## Background

The current implementation in `lib/destila/dev_tools.ex` calls `System.cmd("open", ["-na", "Ghostty.app", ...])` to open the macOS Ghostty desktop app with a tmux session. This has limitations:
- Only works on macOS with Ghostty installed
- Opens a separate app, breaking the browser-based workflow
- Cannot embed the terminal in the web UI

The `ghostty_ex` package (`{:ghostty, "~> 0.3"}`) provides:
- `Ghostty.Terminal` — a GenServer wrapping libghostty-vt (SIMD-optimized VT parser)
- `Ghostty.PTY` — forkpty()-based pseudo-terminal for running interactive subprocesses
- `Ghostty.LiveTerminal.Component` — a stateful LiveComponent that renders the terminal in the browser with keyboard/mouse handling

Together, these allow running a real shell (bash/zsh) on the server and rendering it as an interactive terminal in the browser.

## Architecture

```
Browser Tab (/sessions/:id/terminal)
  └── TerminalLive (LiveView)
        ├── Ghostty.Terminal (GenServer — VT parser, renders cell grid)
        ├── Ghostty.PTY (GenServer — forkpty, runs shell at worktree_path)
        └── Ghostty.LiveTerminal.Component (LiveComponent — renders cells, handles keyboard/mouse)
```

Data flow:
1. User presses a key → Component's `handle_event("key", ...)` captures it → encodes to VT sequence → writes to PTY via `Ghostty.PTY.write/2`
2. PTY subprocess produces output → `{:data, binary}` message sent to LiveView (parent process) → LiveView writes to Terminal → triggers Component refresh via `send_update/3`
3. PTY subprocess exits → `{:exit, status}` message → LiveView shows exit status
4. On initial mount with `fit: true` → Component measures container → sends `{:terminal_ready, id, cols, rows}` to parent → parent resizes PTY to match
5. On subsequent resizes → Component's `handle_event("resize", ...)` resizes both Terminal and PTY internally

Key insight: the Component handles keyboard, mouse, focus, and resize events internally via `phx-target={@myself}`. The parent LiveView only needs to:
- Bridge PTY output (`{:data, data}`) to Terminal + trigger refresh
- Handle initial PTY resize on `{:terminal_ready, ...}`
- Handle PTY exit (`{:exit, status}`)
- Forward terminal query responses (`{:pty_write, data}`) back to PTY

## Step 1 — Add ghostty_ex dependency and set up JS assets

### 1a. Add dependency

**File:** `mix.exs` — add to `deps/0`:

```elixir
{:ghostty, "~> 0.3"}
```

Run `mix deps.get`. The ghostty package depends on `{:oxc, "~> 0.5"}` which bundles its TypeScript source at compile time — running `mix compile` will produce `priv/static/ghostty.js` inside the ghostty dep.

### 1b. Vendor the JS hook

The ghostty_ex installer (`Ghostty.LiveTerminal.Installer`) expects the JS to be vendored at `assets/vendor/ghostty.js`. There are two setup paths:

**Option A — With Igniter** (if `{:igniter, "~> 0.5"}` is already a dependency):
```bash
mix igniter.install ghostty
```
This copies the JS to `assets/vendor/ghostty.js` and patches `assets/js/app.js` automatically.

**Option B — Manual** (no Igniter dependency):
```bash
mix deps.get && mix compile
cp _build/dev/lib/ghostty/priv/static/ghostty.js assets/vendor/ghostty.js
```
Then manually edit `assets/js/app.js` (Step 2).

The JS file is compiled from TypeScript source in the dep's `priv/ts/hook.ts` by the `Mix.Compilers.GhosttyJS` compiler using OXC. The output goes to `_build/dev/lib/ghostty/priv/static/ghostty.js` (accessible at runtime via `:code.priv_dir(:ghostty)`).

## Step 2 — Register the GhosttyTerminal JS hook

**File:** `assets/js/app.js`

Add the import after the existing LiveView import (line 24):

```javascript
import {GhosttyTerminal} from "../vendor/ghostty"
```

Add `GhosttyTerminal` to the existing `Hooks` object (line 56–61):

```javascript
const Hooks = {
  ...colocatedHooks,
  ScrollBottom: ScrollBottomHook,
  FocusFirstError: FocusFirstErrorHook,
  AutoDismiss: AutoDismissHook,
  GhosttyTerminal,
}
```

The hook name **must** be `GhosttyTerminal` — the Component renders `phx-hook="GhosttyTerminal"` and the JS hook registers event handlers for `ghostty:render`, keyboard, mouse, resize, and focus events.

**Why `../vendor/ghostty` and not a package import?** The ghostty dep's `package.json` is `private: true` with no `main` field, so esbuild's NODE_PATH resolution (`deps/ghostty/`) won't find an entry point. The vendor approach matches how other Phoenix assets (topbar, heroicons) are distributed.

## Step 3 — Create the TerminalLive LiveView

**File:** `lib/destila_web/live/terminal_live.ex` (new)

This LiveView manages a single terminal session. It starts `Ghostty.Terminal` and `Ghostty.PTY`, passes them to the Component, and bridges PTY output.

```elixir
defmodule DestilaWeb.TerminalLive do
  use DestilaWeb, :live_view

  alias Destila.AI

  @default_cols 80
  @default_rows 24

  def mount(%{"id" => ws_id}, _session, socket) do
    ai_session = AI.get_ai_session_for_workflow(ws_id)
    worktree_path = ai_session && ai_session.worktree_path

    if worktree_path do
      ws = Destila.Workflows.get_workflow_session!(ws_id)

      socket =
        socket
        |> assign(:ws_id, ws_id)
        |> assign(:page_title, "Terminal — #{ws.title}")
        |> assign(:worktree_path, worktree_path)

      if connected?(socket) do
        shell = System.get_env("SHELL", "/bin/bash")

        with {:ok, term} <- Ghostty.Terminal.start_link(cols: @default_cols, rows: @default_rows),
             {:ok, pty} <- Ghostty.PTY.start_link(cmd: shell, cols: @default_cols, rows: @default_rows) do
          # PTY does not support a :cwd option, so cd to the worktree path.
          # Shell-escape the path to avoid injection from special characters.
          escaped_path = shell_escape(worktree_path)
          Ghostty.PTY.write(pty, "cd #{escaped_path} && clear\n")

          {:ok,
           socket
           |> assign(:term, term)
           |> assign(:pty, pty)
           |> assign(:exited, false)}
        else
          {:error, reason} ->
            {:ok,
             socket
             |> put_flash(:error, "Could not start terminal: #{inspect(reason)}")
             |> assign(:term, nil)
             |> assign(:pty, nil)
             |> assign(:exited, true)}
        end
      else
        # Static render — no processes yet
        {:ok,
         socket
         |> assign(:term, nil)
         |> assign(:pty, nil)
         |> assign(:exited, false)}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "No worktree path for this session")
       |> push_navigate(to: ~p"/sessions/#{ws_id}")}
    end
  end

  # --- handle_info callbacks ---

  # PTY output → write to terminal → trigger component refresh
  def handle_info({:data, data}, socket) do
    Ghostty.Terminal.write(socket.assigns.term, data)
    send_update(Ghostty.LiveTerminal.Component, id: "terminal", refresh: true)
    {:noreply, socket}
  end

  # PTY exited
  def handle_info({:exit, status}, socket) do
    {:noreply, assign(socket, :exited, status)}
  end

  # Terminal ready after fit measurement — resize PTY to match browser dimensions.
  # The Component resizes the Terminal internally on "ready", but sends this message
  # so we can resize the PTY (which the Component's "ready" handler does not do).
  # Subsequent resizes are handled entirely by the Component's "resize" handler
  # which calls Ghostty.LiveTerminal.handle_resize/4 for both Terminal and PTY.
  def handle_info({:terminal_ready, _id, cols, rows}, socket) do
    if socket.assigns.pty do
      Ghostty.PTY.resize(socket.assigns.pty, cols, rows)
    end

    {:noreply, socket}
  end

  # Terminal query responses (e.g. cursor position reports) need to go back to PTY
  def handle_info({:pty_write, data}, socket) do
    if socket.assigns.pty do
      Ghostty.PTY.write(socket.assigns.pty, data)
    end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- render ---

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col h-[calc(100vh-0px)] bg-black">
        <div class="flex items-center gap-3 px-4 py-2 bg-base-200 border-b border-base-300 shrink-0">
          <.link navigate={~p"/sessions/#{@ws_id}"} class="text-base-content/60 hover:text-base-content transition-colors">
            <.icon name="hero-arrow-left-micro" class="size-4" />
          </.link>
          <code class="text-xs text-base-content/50 truncate flex-1">{@worktree_path}</code>
          <span :if={@exited} class="text-xs text-warning">
            Process exited ({@exited})
          </span>
        </div>
        <div id="terminal-container" class="flex-1 min-h-0 overflow-hidden p-1">
          <%= if @term do %>
            <.live_component
              module={Ghostty.LiveTerminal.Component}
              id="terminal"
              term={@term}
              pty={@pty}
              fit={true}
              autofocus={true}
              class="h-full w-full"
            />
          <% else %>
            <div class="flex items-center justify-center h-full text-base-content/40 text-sm">
              <%= if @exited do %>
                Terminal could not start.
              <% else %>
                Connecting...
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- helpers ---

  defp shell_escape(str), do: "'" <> String.replace(str, "'", "'\\''") <> "'"
end
```

### Design decisions

- **`send_update` vs `push_render`**: The Component's `@moduledoc` explicitly shows using `send_update(Ghostty.LiveTerminal.Component, id: "term", refresh: true)` to trigger a re-render after writing data. The Component's internal `update/2` callback checks for `assigns[:refresh]` and calls `push_render` on the socket. Do **not** call `Ghostty.LiveTerminal.push_render/3` directly from the parent — that operates on the wrong socket.

- **Static vs connected render**: Terminal and PTY are only started when `connected?(socket)`. On static render, `@term` is `nil` and the template shows "Connecting..." placeholder. This avoids starting processes that would be immediately orphaned.

- **Error handling via `with`**: If `Ghostty.Terminal.start_link` or `Ghostty.PTY.start_link` fails (e.g., NIF not available), the LiveView still mounts but shows an error flash. The `@exited` assign is set to `true` so the template shows "Terminal could not start."

- **Shell escaping**: The worktree path comes from the database and is constructed by `Destila.Workers.PrepareWorkflowSession` as `Path.join([local_folder, ".claude", "worktrees", session_id])`. While unlikely to contain malicious characters, we escape it with single-quote wrapping to be safe.

- **No `:cwd` option**: `Ghostty.PTY.start_link/1` only accepts `:cmd`, `:args`, `:cols`, `:rows`, and `:name`. There is no `:cwd` or `:env` option. The `cd <path> && clear` approach is the necessary workaround. The user briefly sees the initial directory before `cd` executes, but `clear` hides that.

- **Layout**: The page uses `<Layouts.app>` which includes the sidebar navigation. This keeps the terminal page consistent with the rest of the app — the sidebar is collapsible and defaults to narrow (64px).

- **Flex layout**: `h-[calc(100vh-0px)]` with `flex-1 min-h-0` on the terminal container ensures the terminal fills available space without causing overflow. `min-h-0` is critical in flexbox to allow the child to shrink below its content size.

### What the Component handles internally

Looking at `Ghostty.LiveTerminal.Component` source code (`lib/ghostty/live_terminal/component.ex`):

- `handle_event("key", params, socket)` — keyboard input → encodes VT sequence → writes to PTY (or Terminal if no PTY)
- `handle_event("text", %{"data" => data}, socket)` — paste/IME → writes to PTY
- `handle_event("mouse", params, socket)` — mouse events → encodes and writes
- `handle_event("ready", %{"cols" => cols, "rows" => rows}, socket)` — initial fit measurement → resizes Terminal + sends `{:terminal_ready, id, cols, rows}` to parent
- `handle_event("resize", %{"cols" => cols, "rows" => rows}, socket)` — subsequent resize → calls `Ghostty.LiveTerminal.handle_resize(term, cols, rows, pty)` which resizes **both** Terminal and PTY
- `handle_event("focus", %{"focused" => focused}, socket)` — focus change events
- `handle_event("refresh", _params, socket)` — client-initiated refresh

The parent only needs to handle messages from the PTY process (`{:data, _}`, `{:exit, _}`) and the Terminal process (`{:pty_write, _}`), plus the one-time `{:terminal_ready, ...}` from the Component.

## Step 4 — Add route

**File:** `lib/destila_web/router.ex`

Add the terminal route inside the existing `scope "/", DestilaWeb` block, **before** the `live "/sessions/:id"` catch-all:

```elixir
scope "/", DestilaWeb do
  pipe_through :browser

  live "/", DashboardLive
  live "/crafting", CraftingBoardLive
  live "/projects", ProjectsLive
  live "/workflows", CreateSessionLive
  live "/workflows/:workflow_type", CreateSessionLive
  live "/sessions/archived", ArchivedSessionsLive
  get "/media/:id", MediaController, :show
  live "/sessions/:id/terminal", TerminalLive
  live "/sessions/:id", WorkflowRunnerLive
end
```

Route ordering matters: `/sessions/:id/terminal` must come before `/sessions/:id` to avoid the `:id` param consuming "terminal" as the ID value. Phoenix uses first-match routing.

## Step 5 — Update the "Open Terminal" button to open a new tab

**File:** `lib/destila_web/live/workflow_runner_live.ex` — lines 652–677 (source code section)

Replace the `<button phx-click="open_terminal">` with an `<a>` link that opens in a new tab:

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
    <a
      id="open-terminal-btn"
      href={~p"/sessions/#{@workflow_session.id}/terminal"}
      target="_blank"
      class="p-1 rounded-md hover:bg-base-300/50 transition-colors text-[0px]"
      aria-label="Open terminal in new tab"
    >
      <.icon name="hero-command-line-micro" class="size-4 text-primary" />
    </a>
  </div>
  <code class="text-xs text-base-content/50 break-all leading-relaxed">
    {@worktree_path}
  </code>
</div>
```

Changes:
- `<button phx-click="open_terminal">` → `<a href={...} target="_blank">`
- Keeps same `id="open-terminal-btn"` for test selectors
- Opens `/sessions/:id/terminal` in a new browser tab
- No server event needed — pure client-side navigation

## Step 6 — Remove dead code

### 6a. Delete DevTools module

**File:** `lib/destila/dev_tools.ex` — delete entirely

This module only contained `open_terminal/3` which used `System.cmd("open", ...)` to launch the Ghostty desktop app. No longer needed.

### 6b. Remove the `open_terminal` event handler

**File:** `lib/destila_web/live/workflow_runner_live.ex` — lines 321–333

Delete the entire `handle_event("open_terminal", ...)` handler.

### 6c. Remove the DevTools alias

**File:** `lib/destila_web/live/workflow_runner_live.ex` — line 21

Remove:
```elixir
alias Destila.DevTools
```

## Step 7 — Process lifecycle

Terminal and PTY GenServers are started with `start_link`, linking them to the LiveView process. When the user closes the browser tab, the LiveView terminates and linked processes are automatically cleaned up. No explicit `terminate/2` callback needed.

If the PTY exits before the user closes the tab (e.g., user types `exit` in the shell), the `{:exit, status}` handler sets `@exited` which renders an exit message in the header bar. The terminal display remains visible (showing the last output) but keyboard input stops working since the PTY is dead.

If the user opens multiple terminal tabs for the same session, each tab gets its own independent Terminal + PTY pair. There's no shared state between tabs — each is a fresh shell. This is acceptable for a development tool.

## Step 8 — Update feature file

**File:** `features/exported_metadata.feature` — replace lines 118–130 (the Source Code Terminal section)

```gherkin
  # --- Source Code Terminal ---

  Scenario: Source code section shows open terminal link
    Given I am on a session detail page
    And the session has a worktree path
    Then the source code section should display an "Open Terminal" link to the terminal page

  Scenario: Terminal page renders an interactive terminal
    Given I am on a session detail page
    And the session has a worktree path
    When I open the terminal page in a new tab
    Then I should see an interactive terminal at the worktree path
    And the terminal header should show a back link to the session
```

## Step 9 — Update tests

### 9a. Update existing sidebar link test

**File:** `test/destila_web/live/open_terminal_live_test.exs`

```elixir
defmodule DestilaWeb.OpenTerminalLiveTest do
  @moduledoc """
  LiveView tests for Open Terminal link in sidebar.
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

  describe "open terminal link" do
    @tag feature: "exported_metadata",
         scenario: "Source code section shows open terminal link"
    test "link is present when worktree path exists", %{conn: conn} do
      {_ws, view} = create_session_with_worktree(conn)

      assert has_element?(view, "#open-terminal-btn")
    end

    @tag feature: "exported_metadata",
         scenario: "Source code section shows open terminal link"
    test "link points to terminal page with target=_blank", %{conn: conn} do
      {ws, view} = create_session_with_worktree(conn)

      assert has_element?(view, ~s(a#open-terminal-btn[href="/sessions/#{ws.id}/terminal"][target="_blank"]))
    end
  end
end
```

### 9b. Add TerminalLive test

**File:** `test/destila_web/live/terminal_live_test.exs` (new)

```elixir
defmodule DestilaWeb.TerminalLiveTest do
  @moduledoc """
  LiveView tests for in-browser terminal.
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

  defp create_session_with_worktree do
    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test Terminal Session",
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

    ws
  end

  describe "terminal page" do
    @tag feature: "exported_metadata",
         scenario: "Terminal page renders an interactive terminal"
    test "mounts and shows terminal container", %{conn: conn} do
      ws = create_session_with_worktree()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/terminal")

      assert has_element?(view, "#terminal-container")
    end

    @tag feature: "exported_metadata",
         scenario: "Terminal page renders an interactive terminal"
    test "shows back link to session page", %{conn: conn} do
      ws = create_session_with_worktree()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/terminal")

      assert has_element?(view, ~s(a[href="/sessions/#{ws.id}"]))
    end

    @tag feature: "exported_metadata",
         scenario: "Terminal page renders an interactive terminal"
    test "displays worktree path in header", %{conn: conn} do
      ws = create_session_with_worktree()
      {:ok, _view, html} = live(conn, ~p"/sessions/#{ws.id}/terminal")

      assert html =~ "/tmp/test-worktree"
    end

    @tag feature: "exported_metadata",
         scenario: "Terminal page renders an interactive terminal"
    test "redirects when session has no worktree path", %{conn: conn} do
      {:ok, ws} =
        Destila.Workflows.insert_workflow_session(%{
          title: "No Worktree",
          workflow_type: :brainstorm_idea,
          project_id: nil,
          done_at: DateTime.utc_now(),
          current_phase: 4,
          total_phases: 4
        })

      # push_navigate fires on static mount, redirecting to the session page
      assert {:error, {:live_redirect, %{to: "/sessions/" <> _}}} =
               live(conn, ~p"/sessions/#{ws.id}/terminal")
    end
  end
end
```

### Test notes

- **Static render tests work without NIF**: The `live/2` function first does a static render (disconnected mount), then connects. If the NIF is unavailable, the static render still works because Terminal/PTY are only started on connected mount. The connected mount would fail with an error flash but the LiveView survives.
- **Redirect test**: When `worktree_path` is nil, `push_navigate` fires during mount. In LiveView tests, this manifests as `{:error, {:live_redirect, %{to: path}}}` from `live/2`.
- **No mocking of Ghostty**: Tests exercise real mount paths. The connected mount tests may start actual Terminal/PTY processes if the NIF is available — they'll be cleaned up when the LiveView process exits at test end.

## Files changed

| File | Change |
|---|---|
| `mix.exs` | Add `{:ghostty, "~> 0.3"}` dependency |
| `assets/vendor/ghostty.js` | New — vendored JS hook (copied from dep's `priv/static/ghostty.js`) |
| `assets/js/app.js` | Import `GhosttyTerminal` from vendor, add to `Hooks` object |
| `lib/destila_web/live/terminal_live.ex` | New LiveView for browser terminal |
| `lib/destila_web/router.ex` | Add `live "/sessions/:id/terminal", TerminalLive` route |
| `lib/destila_web/live/workflow_runner_live.ex` | Replace `<button>` with `<a>` link (lines 665–672), remove `handle_event("open_terminal", ...)` (lines 321–333), remove `alias Destila.DevTools` (line 21) |
| `lib/destila/dev_tools.ex` | Delete entirely |
| `features/exported_metadata.feature` | Update terminal scenarios (lines 118–130) |
| `test/destila_web/live/open_terminal_live_test.exs` | Update tests for link-based approach |
| `test/destila_web/live/terminal_live_test.exs` | New test file for TerminalLive |

## Risks & considerations

1. **NIF availability**: ghostty_ex provides precompiled binaries for x86_64 Linux, aarch64 Linux, and aarch64 macOS. On other platforms, compilation requires Zig 0.15+. The `with` clause in mount handles startup failures gracefully — the page shows an error flash instead of crashing.

2. **Security**: The PTY runs a real shell on the server with the same permissions as the Phoenix app. This is acceptable for Destila (a single-user local development tool — auth was removed in PR #82). This feature should **not** be deployed on a multi-user or publicly accessible instance.

3. **Resource cleanup**: Terminal and PTY are `start_link`'d to the LiveView process, so they auto-terminate when the tab closes. Each open terminal tab consumes one PTY file descriptor and one shell process. This is bounded by browser tab limits and acceptable for development use.

4. **Working directory**: `Ghostty.PTY.start_link/1` does **not** support a `:cwd` option (confirmed — only `:cmd`, `:args`, `:cols`, `:rows`, `:name`). The `cd <path> && clear\n` workaround is necessary. The path is shell-escaped with single-quote wrapping to prevent injection.

5. **OXC dependency**: ghostty_ex pulls in `{:oxc, "~> 0.5"}` for TypeScript compilation at build time. This adds a build dependency but has no runtime overhead — OXC is only used during `mix compile`.

6. **JS asset regeneration**: If the ghostty dep is updated, the vendored `assets/vendor/ghostty.js` must be re-copied. Running `mix igniter.install ghostty` again handles this, or manually: `cp _build/dev/lib/ghostty/priv/static/ghostty.js assets/vendor/ghostty.js`.
