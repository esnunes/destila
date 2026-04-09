# Feature: User Prompt in Sidebar

Display the session's `user_prompt` as a new section at the top of the workflow runner's right sidebar. Clicking a view button opens the existing markdown modal to render the prompt content.

## Step 1 — Add `user_prompt_modal_open` assign

**File:** `lib/destila_web/live/workflow_runner_live.ex` — line 67 area

Add a new boolean assign alongside the existing modal assigns:

```elixir
|> assign(:user_prompt_modal_open, false)
```

Insert after line 67 (`assign(:markdown_modal_meta_id, nil)`).

## Step 2 — Add event handlers for the user prompt modal

**File:** `lib/destila_web/live/workflow_runner_live.ex` — after line 303

Add two new event handlers following the same pattern as `open_markdown_modal`/`close_markdown_modal`:

```elixir
def handle_event("open_user_prompt_modal", _params, socket) do
  {:noreply, assign(socket, :user_prompt_modal_open, true)}
end

def handle_event("close_user_prompt_modal", _params, socket) do
  {:noreply, assign(socket, :user_prompt_modal_open, false)}
end
```

No `phx-value-id` needed — there's only one user prompt per session.

## Step 3 — Add the "User Prompt" sidebar section

**File:** `lib/destila_web/live/workflow_runner_live.ex` — line 586 (inside `#metadata-sidebar-content`, before the "Source Code" section)

Insert a new section block above the source code section (before line 587). It follows the same visual pattern as the markdown metadata sidebar entry:

```heex
<%!-- User prompt section --%>
<div
  :if={@workflow_session.user_prompt not in [nil, ""]}
  id="user-prompt-section"
  class="p-4 border-b border-base-300/60"
>
  <div class="flex items-center gap-2 mb-3">
    <.icon
      name="hero-chat-bubble-left-ellipsis-micro"
      class="size-4 text-base-content/30"
    />
    <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wide">
      User Prompt
    </h3>
  </div>
  <div class="flex items-center gap-2 px-3 py-2 rounded-lg border border-base-300/60 hover:bg-base-200/50 transition-colors duration-150">
    <.icon
      name="hero-document-text-micro"
      class="size-3 text-base-content/30 shrink-0"
    />
    <span class="font-medium text-sm text-base-content/70 truncate flex-1">
      Prompt
    </span>
    <button
      id="view-user-prompt-btn"
      phx-click="open_user_prompt_modal"
      class="p-1 rounded-md hover:bg-base-300/50 transition-colors"
      aria-label="View user prompt"
    >
      <.icon name="hero-eye-micro" class="size-4 text-primary" />
    </button>
  </div>
</div>
```

Key decisions:
- Uses `hero-chat-bubble-left-ellipsis-micro` for the section header icon (distinguishes it from exported metadata document icons)
- Uses `hero-document-text-micro` + `hero-eye-micro` for the entry row, matching the markdown metadata pattern
- Conditional on `@workflow_session.user_prompt not in [nil, ""]` — renders nothing when absent or empty
- Has a stable `id="user-prompt-section"` for test selectors

## Step 4 — Add the user prompt modal

**File:** `lib/destila_web/live/workflow_runner_live.ex` — after the existing markdown modal block (after line 767)

Insert a new modal block that reuses `<.markdown_viewer>`:

```heex
<%!-- User prompt modal --%>
<%= if @user_prompt_modal_open do %>
  <div
    id="user-prompt-modal"
    class="fixed inset-0 z-50 flex items-center justify-center"
  >
    <div
      class="absolute inset-0 bg-black/70 backdrop-blur-sm"
      phx-click="close_user_prompt_modal"
    />
    <div class="relative z-10 w-full max-w-3xl mx-4">
      <button
        phx-click="close_user_prompt_modal"
        class="absolute -top-10 right-0 text-white/70 hover:text-white transition-colors"
        aria-label="Close user prompt"
      >
        <.icon name="hero-x-mark" class="size-6" />
      </button>
      <div class="rounded-xl bg-base-200 shadow-2xl overflow-hidden">
        <.markdown_viewer
          id="user-prompt-modal-viewer"
          content={@workflow_session.user_prompt}
          label="User Prompt"
        />
      </div>
    </div>
  </div>
<% end %>
```

Identical structure to the existing markdown modal but sources content from `@workflow_session.user_prompt` instead of metadata.

## Step 5 — Update Gherkin feature file

**File:** `features/exported_metadata.feature` — append after line 105

Add a new section with three scenarios:

```gherkin

  # --- User Prompt in Sidebar ---

  Scenario: User prompt appears at the top of the sidebar
    Given I am on a session detail page
    And the session has a user prompt
    Then the sidebar should show a "User Prompt" section above the source code section
    And the section should display a view button

  Scenario: User prompt section is hidden when prompt is empty
    Given I am on a session detail page
    And the session has no user prompt
    Then the sidebar should not show a "User Prompt" section

  Scenario: Open user prompt in markdown modal
    Given I am on a session detail page
    And the session has a user prompt
    When I click the view button on the user prompt section
    Then a full-screen modal overlay should appear with a dark backdrop
    And the modal should display the user prompt content with "Rendered" and "Markdown" tabs
    And the modal should default to the rendered HTML view
```

## Step 6 — Write LiveView tests

**File:** `test/destila_web/live/user_prompt_sidebar_live_test.exs` (new file)

Follow the same patterns as `markdown_metadata_viewing_live_test.exs`: setup with `ClaudeCode.Test`, login, create a workflow session, then navigate to `/sessions/:id`.

```elixir
defmodule DestilaWeb.UserPromptSidebarLiveTest do
  @moduledoc """
  LiveView tests for User Prompt in Sidebar.
  Feature: features/exported_metadata.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @sample_user_prompt """
  Fix the login timeout bug by increasing the session TTL from 30 to 60 minutes.

  ## Steps

  1. Update `config/runtime.exs`
  2. Change `session_ttl` from 30 to 60 minutes
  3. Add a test for the new timeout value
  """

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

  defp create_session(attrs \\ %{}) do
    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(
        Map.merge(
          %{
            title: "Test Session",
            workflow_type: :brainstorm_idea,
            project_id: nil,
            done_at: DateTime.utc_now(),
            current_phase: 4,
            total_phases: 4
          },
          attrs
        )
      )

    ws
  end

  describe "user prompt sidebar section" do
    @tag feature: "exported_metadata", scenario: "User prompt appears at the top of the sidebar"
    test "shows user prompt section with view button when prompt exists", %{conn: conn} do
      ws = create_session(%{user_prompt: @sample_user_prompt})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#user-prompt-section")
      assert has_element?(view, "#view-user-prompt-btn")

      # Verify it appears before source code (both exist in sidebar)
      html = render(view)
      user_prompt_pos = :binary.match(html, "user-prompt-section") |> elem(0)
      # The section should exist in the rendered HTML
      assert user_prompt_pos > 0
    end

    @tag feature: "exported_metadata", scenario: "User prompt section is hidden when prompt is empty"
    test "hides user prompt section when prompt is nil", %{conn: conn} do
      ws = create_session(%{user_prompt: nil})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      refute has_element?(view, "#user-prompt-section")
    end

    @tag feature: "exported_metadata", scenario: "User prompt section is hidden when prompt is empty"
    test "hides user prompt section when prompt is empty string", %{conn: conn} do
      ws = create_session(%{user_prompt: ""})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      refute has_element?(view, "#user-prompt-section")
    end
  end

  describe "user prompt modal" do
    @tag feature: "exported_metadata", scenario: "Open user prompt in markdown modal"
    test "clicking view button opens modal with markdown viewer", %{conn: conn} do
      ws = create_session(%{user_prompt: @sample_user_prompt})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("#view-user-prompt-btn") |> render_click()

      assert has_element?(view, "#user-prompt-modal")
      assert has_element?(view, "#user-prompt-modal-viewer")
      assert has_element?(view, "#user-prompt-modal-viewer [role='tablist']")
      assert has_element?(view, "#user-prompt-modal-viewer button[data-view='rendered']")
      assert has_element?(view, "#user-prompt-modal-viewer button[data-view='markdown']")
      assert has_element?(view, "#user-prompt-modal-viewer [data-rendered]")
      assert has_element?(view, "#user-prompt-modal-viewer [data-markdown]")
    end

    @tag feature: "exported_metadata", scenario: "Open user prompt in markdown modal"
    test "clicking close button dismisses the modal", %{conn: conn} do
      ws = create_session(%{user_prompt: @sample_user_prompt})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("#view-user-prompt-btn") |> render_click()
      assert has_element?(view, "#user-prompt-modal")

      view
      |> element("#user-prompt-modal button[phx-click='close_user_prompt_modal']")
      |> render_click()

      refute has_element?(view, "#user-prompt-modal")
    end
  end
end
```

## Files Changed

| File | Change |
|---|---|
| `lib/destila_web/live/workflow_runner_live.ex` | Add `user_prompt_modal_open` assign, two event handlers, sidebar section, and modal |
| `features/exported_metadata.feature` | Add three Gherkin scenarios under `# --- User Prompt in Sidebar ---` |
| `test/destila_web/live/user_prompt_sidebar_live_test.exs` | New test file with tests for all three scenarios |

## Notes

- No schema or migration changes — `user_prompt` is already a first-class column on Session
- The `<.markdown_viewer>` component accepts any string as `content`, so it works directly with `@workflow_session.user_prompt`
- Uses a separate boolean assign (`@user_prompt_modal_open`) rather than overloading `@markdown_modal_meta_id`, keeping the two modal flows independent
