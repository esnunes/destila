# Feature: Open Terminal Button in Source Code Sidebar

Add an "Open Terminal" button to the Source Code sidebar section. Clicking it opens a new Ghostty terminal window at the session's worktree path.

## Dependency note

The `ghostty_ex` library (`{:ghostty, "~> 0.2"}`) is a terminal emulator for the BEAM — it wraps `libghostty-vt` for SIMD-optimized VT parsing. It does **not** provide an API for controlling the Ghostty desktop application (opening tabs, windows, etc.).

To open a Ghostty terminal at a path, use `System.cmd/3` with macOS's `open` command:

```elixir
System.cmd("open", ["-na", "Ghostty.app", "--args", "--working-directory=" <> path])
```

This opens a new Ghostty window at the given directory. Ghostty's CLI `+new-tab` action is not supported on macOS, so a new window is the reliable mechanism.

## Step 1 — Add "Open Terminal" button to source code section

**File:** `lib/destila_web/live/workflow_runner_live.ex` — lines 637–654

Replace the current source code section template with a version that includes the button in the section header row, matching the user prompt section's pattern:

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
      phx-click="open_terminal"
      class="p-1 rounded-md hover:bg-base-300/50 transition-colors"
      aria-label="Open terminal at worktree path"
    >
      <.icon name="hero-command-line-micro" class="size-4 text-primary" />
    </button>
  </div>
  <code class="text-xs text-base-content/50 break-all leading-relaxed">
    {@worktree_path}
  </code>
</div>
```

Key decisions:
- Button placed in the section header row (same pattern as user prompt section's view button row)
- Uses `hero-command-line-micro` icon (terminal icon from Heroicons v2.2.0)
- Has stable `id="open-terminal-btn"` for test selectors
- The section's existing `:if={@worktree_path}` guard means the button only renders when the path is set

## Step 2 — Add event handler

**File:** `lib/destila_web/live/workflow_runner_live.ex` — after line 318 (after `close_markdown_modal` handler)

```elixir
def handle_event("open_terminal", _params, socket) do
  path = socket.assigns.worktree_path

  case System.cmd("open", ["-na", "Ghostty.app", "--args", "--working-directory=" <> path],
         stderr_to_stdout: true
       ) do
    {_, 0} ->
      {:noreply, socket}

    {output, _} ->
      {:noreply, put_flash(socket, :error, "Could not open Ghostty: #{String.trim(output)}")}
  end
end
```

The handler:
- Reads `worktree_path` from assigns (guaranteed non-nil since the button is only rendered when the path exists)
- Uses `System.cmd/3` to open a new Ghostty window at the worktree path
- On failure (e.g., Ghostty not installed), shows a flash error with the output

## Step 3 — Update Gherkin feature file

**File:** `features/exported_metadata.feature` — append after line 117 (after the User Prompt section)

```gherkin

  # --- Source Code Terminal ---

  Scenario: Source code section shows open terminal button
    Given I am on a session detail page
    And the session has a worktree path
    Then the source code section should display an "Open Terminal" button

  Scenario: Open terminal button opens a Ghostty tab at the worktree path
    Given I am on a session detail page
    And the session has a worktree path
    When I click the "Open Terminal" button
    Then a new Ghostty terminal tab should open at the worktree path
```

## Step 4 — Write tests

**File:** `test/destila_web/live/open_terminal_live_test.exs` (new file)

```elixir
defmodule DestilaWeb.OpenTerminalLiveTest do
  @moduledoc """
  LiveView tests for Open Terminal button in sidebar.
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

    # Create an AI session with a worktree path so the sidebar renders the section
    {:ok, _ai_session} =
      Destila.AI.create_ai_session(%{
        workflow_session_id: ws.id,
        worktree_path: "/tmp/test-worktree"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")
    {ws, view}
  end

  describe "open terminal button" do
    @tag feature: "exported_metadata",
         scenario: "Source code section shows open terminal button"
    test "button is present when worktree path exists", %{conn: conn} do
      {_ws, view} = create_session_with_worktree(conn)

      assert has_element?(view, "#open-terminal-btn")
    end

    @tag feature: "exported_metadata",
         scenario: "Open terminal button opens a Ghostty tab at the worktree path"
    test "clicking the button sends the open_terminal event", %{conn: conn} do
      {_ws, view} = create_session_with_worktree(conn)

      # Click the button — the System.cmd call will likely fail in test
      # (Ghostty not running), but we verify the event is handled without crash
      view |> element("#open-terminal-btn") |> render_click()

      # The LiveView should still be alive (event was handled gracefully)
      assert has_element?(view, "#open-terminal-btn")
    end
  end
end
```

Notes on tests:
- The first test verifies the button renders when a worktree path exists
- The second test clicks the button to verify the event handler runs without crashing. In CI/test environments Ghostty won't be running, so the handler will show a flash error — the test confirms the LiveView survives the event
- No mocking of `System.cmd` — the test exercises the real handler and verifies the LiveView doesn't crash
- The helper `create_session_with_worktree/1` creates both a workflow session and its associated AI session with a worktree path, since `assign_worktree_path/2` reads from `Destila.AI.get_ai_session_for_workflow/1`

## Files changed

| File | Change |
|---|---|
| `lib/destila_web/live/workflow_runner_live.ex` | Add button to source code section template, add `open_terminal` event handler |
| `features/exported_metadata.feature` | Add two Gherkin scenarios under `# --- Source Code Terminal ---` |
| `test/destila_web/live/open_terminal_live_test.exs` | New test file with two tests |

## Notes

- No new dependencies needed — `System.cmd/3` is part of Elixir's standard library
- The `hero-command-line-micro` icon is confirmed present at `deps/heroicons/optimized/20/solid/command-line.svg`
- The test helper uses `Destila.AI.create_ai_session(%{workflow_session_id: id, worktree_path: path})` — confirmed via `lib/destila/ai.ex:46` and `lib/destila/ai/session.ex`. Only `workflow_session_id` is required by the changeset; `worktree_path` is an optional string field
