# Feature: Code Chat Workflow

A new single-phase, interactive workflow that provides a free-form chat experience with AI — similar to Claude Code. No phase transitions, no structured pipeline. The user types messages and the AI responds with full tool access.

## Step 1 — Add `:code_chat` to the Session schema enum

**File:** `lib/destila/workflows/session.ex` — line 9

Add `:code_chat` to the `Ecto.Enum` values list:

```elixir
field(:workflow_type, Ecto.Enum, values: [:brainstorm_idea, :implement_general_prompt, :code_chat])
```

## Step 2 — Create the Ecto migration

**File:** `priv/repo/migrations/<timestamp>_add_code_chat_workflow_type.exs`

SQLite stores Ecto.Enum values as strings, so no column changes are needed — just a migration record. Follow the pattern from `20260406150010_convert_phase_execution_status_to_enum.exs`:

```elixir
defmodule Destila.Repo.Migrations.AddCodeChatWorkflowType do
  use Ecto.Migration

  def change do
    # No column changes needed: SQLite stores Ecto.Enum values as their string
    # representation. This migration records the addition of :code_chat to
    # the workflow_type enum in the migration history.
  end
end
```

## Step 3 — Create the CodeChatWorkflow module

**File:** `lib/destila/workflows/code_chat_workflow.ex`

Follow the `use Destila.Workflows.Workflow` pattern from existing workflows. Single phase, interactive, with a general-purpose coding assistant system prompt.

```elixir
defmodule Destila.Workflows.CodeChatWorkflow do
  @moduledoc """
  Defines the Code Chat workflow — a free-form, open-ended chat experience
  with AI that has full access to code tools and write permissions.

  Single phase: Chat — stays open until the user manually marks it as done.
  No phase transitions, no autonomous steps, no structured pipeline.
  """

  use Destila.Workflows.Workflow

  alias Destila.Workflows.Phase

  @chat_tools [
    "Read",
    "Write",
    "Edit",
    "Bash",
    "Glob",
    "Grep",
    "WebFetch",
    "Skill",
    "mcp__destila__ask_user_question",
    "mcp__destila__session"
  ]

  def phases do
    [
      %Phase{
        name: "Chat",
        system_prompt: &chat_prompt/1,
        allowed_tools: @chat_tools
      }
    ]
  end

  def creation_config, do: {nil, "Message", "user_prompt"}

  def default_title, do: "New Chat"

  def label, do: "Code Chat"
  def description, do: "Chat with AI with full access to tools and write permissions"
  def icon, do: "hero-chat-bubble-left-right"
  def icon_class, do: "text-accent"

  def completion_message, do: "Chat session complete."

  # --- AI System Prompt ---

  defp chat_prompt(workflow_session) do
    metadata = Destila.Workflows.get_metadata(workflow_session.id)
    user_prompt = get_in(metadata, ["user_prompt", "text"])

    user_context =
      if user_prompt && user_prompt != "" do
        "\n\nThe user's initial message:\n#{user_prompt}"
      else
        ""
      end

    """
    You are a general-purpose coding assistant. Help the user with any coding \
    task — reading, writing, editing files, running commands, searching the \
    codebase, debugging, refactoring, or answering questions about code.

    You have full access to code tools and write permissions. Use them freely \
    to assist the user.

    Guidelines:
    - Be direct and helpful
    - Use tools proactively when they would help answer the user's question
    - When making changes, explain what you did and why
    - Ask clarifying questions when the request is ambiguous

    When asking questions with clear, discrete options, use the \
    `mcp__destila__ask_user_question` tool to present structured choices. \
    The tool accepts a `questions` array — batch all your independent questions \
    in a single call. An 'Other' free-text input is always available automatically.

    For open-ended questions without clear options, just ask in plain text.

    To store a key-value pair as session metadata, call `mcp__destila__session` with \
    `action: "export"`, a `key` string, and a `value` string.

    IMPORTANT: Never call `mcp__destila__session` with `suggest_phase_complete` or \
    `phase_complete`. The user controls when this session ends via the UI.
    """ <> user_context
  end
end
```

Key decisions:
- `icon_class: "text-accent"` — distinguishes from brainstorm (`text-warning`) and implement (`text-primary`)
- System prompt explicitly forbids phase completion calls
- `mcp__destila__ask_user_question` included for structured questions
- `mcp__destila__session` included for export only (system prompt forbids phase transitions)
- Session strategy defaults to `:resume` (Phase struct default) — conversation context persists across messages
- `non_interactive` defaults to `false` (Phase struct default) — user can interact

## Step 4 — Register in the dispatcher

**File:** `lib/destila/workflows.ex` — lines 12-15

Add the new workflow to `@workflow_modules`:

```elixir
@workflow_modules %{
  brainstorm_idea: Destila.Workflows.BrainstormIdeaWorkflow,
  implement_general_prompt: Destila.Workflows.ImplementGeneralPromptWorkflow,
  code_chat: Destila.Workflows.CodeChatWorkflow
}
```

## Step 5 — Add badge helpers in BoardComponents

**File:** `lib/destila_web/components/board_components.ex`

Add a `workflow_label/1` clause (line ~186):

```elixir
def workflow_label(:code_chat), do: "Code Chat"
```

Add a `workflow_badge_class/1` clause (line ~190):

```elixir
defp workflow_badge_class(:code_chat), do: "badge-accent"
```

## Step 6 — Hide progress bar for single-phase workflows

**File:** `lib/destila_web/live/workflow_runner_live.ex` — lines 468-485

The progress bar and "Phase X/Y" text are currently always shown in the header. Wrap them with a condition that hides them when `total_phases == 1`:

Replace:

```heex
<div class="flex items-center gap-2">
  <div class="w-24">
    <.progress_indicator
      completed={@workflow_session.current_phase}
      total={@workflow_session.total_phases}
    />
  </div>
  <span class="text-xs text-base-content/40">
    Phase {@workflow_session.current_phase}/{@workflow_session.total_phases}
    <span
      :if={Workflows.phase_name(@workflow_type, @workflow_session.current_phase)}
      class="hidden sm:inline"
    >
      — {Workflows.phase_name(@workflow_type, @workflow_session.current_phase)}
    </span>
  </span>
</div>
```

With:

```heex
<div :if={@workflow_session.total_phases > 1} class="flex items-center gap-2">
  <div class="w-24">
    <.progress_indicator
      completed={@workflow_session.current_phase}
      total={@workflow_session.total_phases}
    />
  </div>
  <span class="text-xs text-base-content/40">
    Phase {@workflow_session.current_phase}/{@workflow_session.total_phases}
    <span
      :if={Workflows.phase_name(@workflow_type, @workflow_session.current_phase)}
      class="hidden sm:inline"
    >
      — {Workflows.phase_name(@workflow_type, @workflow_session.current_phase)}
    </span>
  </span>
</div>
```

The only change is adding `:if={@workflow_session.total_phases > 1}` to the outer `<div>`. This is generic — it applies to any single-phase workflow, not just Code Chat.

Also hide the progress bar on crafting board cards for single-phase workflows.

**File:** `lib/destila_web/components/board_components.ex` — line 135

The `crafting_card` component renders a progress indicator. Add a condition:

```heex
<.progress_indicator
  :if={!@compact && @card.total_phases > 1}
  completed={@card.current_phase}
  total={@card.total_phases}
/>
```

## Step 7 — Hide "Phase N — Name" divider for single-phase workflows

**File:** `lib/destila_web/components/chat_components.ex` — lines 53-87

In the `chat_phase/1` component, the phase group dividers show "Phase 1 — Chat" which is redundant for a single-phase workflow. The phase sections are rendered as `<details>` with a `<summary>` showing the phase name.

For single-phase workflows, replace the `<details>` wrapper with a plain `<div>` that has no collapsible header. Add a `total_phases` assign:

In the `chat_phase/1` function, add to the assigns computation:

```elixir
|> assign(:total_phases, assigns.workflow_session.total_phases)
```

Then in the template, wrap the phase loop with a condition. When `total_phases == 1`, render messages directly without the `<details>` wrapper and phase divider:

```heex
<%= for {phase, group} <- @phase_groups do %>
  <%= if @total_phases > 1 do %>
    <details
      id={"phase-section-#{phase}"}
      phx-hook=".PhaseToggle"
      class={["phase-section", phase == elem(hd(@phase_groups), 0) && "first-phase"]}
      open={phase >= @phase_number}
    >
      <summary class="flex items-center gap-3 my-6 cursor-pointer group list-none">
        <div class="flex-1 h-px bg-base-300" />
        <span class="flex items-center gap-1.5 text-xs font-medium text-base-content/40 uppercase tracking-wide group-hover:text-base-content/60 transition-colors">
          Phase {phase} — {Workflows.phase_name(@workflow_session.workflow_type, phase)}
          <.icon name="hero-chevron-down-micro" class="size-3 phase-chevron" />
        </span>
        <div class="flex-1 h-px bg-base-300" />
      </summary>
      <.chat_message
        :for={msg <- group}
        message={msg}
        workflow_session={@workflow_session}
        phase_status={@phase_status}
      />
      <%!-- setup/processing indicators unchanged --%>
    </details>
  <% else %>
    <div id={"phase-section-#{phase}"}>
      <.chat_message
        :for={msg <- group}
        message={msg}
        workflow_session={@workflow_session}
        phase_status={@phase_status}
      />
      <%= if phase == @phase_number && @phase_status == :setup do %>
        <div class="flex items-center gap-3 text-sm pl-2 mt-2">
          <span class="loading loading-spinner loading-xs shrink-0" />
          <span class="text-base-content/60">Preparing workspace...</span>
        </div>
      <% end %>
      <%= if phase == @phase_number && @phase_status == :processing do %>
        <%= if @streaming_chunks && @streaming_chunks != [] do %>
          <.chat_stream_debug chunks={@streaming_chunks} />
        <% else %>
          <.chat_typing_indicator />
        <% end %>
      <% end %>
    </div>
  <% end %>
<% end %>
```

## Step 8 — Update feature files and tests

### Feature file

**File:** `features/code_chat_workflow.feature`

Create a new Gherkin feature file for the Code Chat workflow:

```gherkin
Feature: Code Chat Workflow
  As a user, I want a free-form chat experience with AI that has full tool
  access, so I can get help with any coding task without a structured pipeline.

  Scenario: Create a new Code Chat session
    Given I am on the crafting board
    When I create a new "Code Chat" session with message "Help me refactor this module"
    Then I should see a chat session titled "New Chat"
    And the session should be in Phase 1 - Chat
    And the progress bar should not be visible

  Scenario: Send messages in the chat
    Given I have an active Code Chat session
    When I type a message and send it
    Then the AI should respond
    And I should be able to send another message

  Scenario: Mark chat session as done
    Given I have an active Code Chat session
    And the AI has responded to my messages
    When I click "Mark as Done"
    Then the session should be marked as complete
    And I should see the completion message "Chat session complete."

  Scenario: No phase transitions in Code Chat
    Given I have an active Code Chat session
    Then there should be no phase advance buttons
    And the session should stay in Phase 1 - Chat
```

### Test file

**File:** `test/destila_web/live/code_chat_workflow_live_test.exs`

Tests should verify:
- Session creation with `:code_chat` workflow type
- Single phase (no progress bar rendered)
- Text input always available
- Mark as Done available on phase 1 (since `current_phase == total_phases == 1`)
- No phase advance UI elements

## Files Changed

| File | Change |
|---|---|
| `lib/destila/workflows/session.ex` | Add `:code_chat` to `Ecto.Enum` values |
| `priv/repo/migrations/<ts>_add_code_chat_workflow_type.exs` | Migration record for new enum value |
| `lib/destila/workflows/code_chat_workflow.ex` | New workflow module (single phase, interactive) |
| `lib/destila/workflows.ex` | Register `:code_chat` in `@workflow_modules` |
| `lib/destila_web/components/board_components.ex` | Add `workflow_label/1` and `workflow_badge_class/1` for `:code_chat`; hide progress bar on cards for single-phase |
| `lib/destila_web/live/workflow_runner_live.ex` | Hide progress bar + phase text when `total_phases == 1` |
| `lib/destila_web/components/chat_components.ex` | Skip phase dividers for single-phase workflows |
| `features/code_chat_workflow.feature` | New Gherkin feature file |
| `test/destila_web/live/code_chat_workflow_live_test.exs` | New test file |
