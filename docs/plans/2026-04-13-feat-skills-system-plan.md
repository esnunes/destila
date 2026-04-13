# Plan: Add a Skills System to the Workflow Engine

## Goal

Introduce a skills system that loads shared markdown files with YAML frontmatter from `priv/skills/` and injects them into AI prompts during prompt assembly. Skills provide reusable context across workflows — "always-included" skills are injected into every prompt, while "on-demand" skills are declared per-phase.

After the skills system works, migrate the duplicated `@tool_instructions` and `@non_interactive_tool_instructions` module attributes into skill files.

## Context

- Prompt assembly happens in `conversation.ex:19-28`: `prompt_fn.(ws)` returns a string that becomes the query passed to the AI worker
- The `Phase` struct (`phase.ex:8-15`) has fields `:name`, `:system_prompt`, `:non_interactive`, `:allowed_tools`, `:session_strategy`
- Three workflow modules exist with two shared instruction blocks:
  - `@tool_instructions` in `brainstorm_idea_workflow.ex:45-83` — for interactive phases (asking questions, suggest_phase_complete)
  - `@non_interactive_tool_instructions` in `implement_general_prompt_workflow.ex:36-55` — for autonomous phases (phase_complete only)
- Both are concatenated into prompt strings via `<> @tool_instructions` at the end of prompt functions
- `code_chat_workflow.ex` inlines similar instructions directly in its prompt function

## Changes

### 1. Create `Destila.Workflows.Skills` module

**File:** `lib/destila/workflows/skills.ex`

This module discovers, parses, and serves skill files from `priv/skills/`.

```elixir
defmodule Destila.Workflows.Skills do
  @moduledoc """
  Discovers and loads skill files from priv/skills/.

  A skill is a markdown file with YAML frontmatter containing at minimum
  `name` and `always` fields. Skills marked `always: true` are injected into
  every AI prompt. Other skills are loaded on-demand by identifier.
  """

  @skills_dir "priv/skills"

  @doc """
  Returns all skills marked with `always: true`.
  """
  def always_included do
    all_skills()
    |> Enum.filter(& &1.always)
  end

  @doc """
  Returns skills matching the given identifiers (filenames without extension).
  """
  def by_identifiers(identifiers) do
    all = all_skills()
    Enum.filter(all, &(&1.identifier in identifiers))
  end

  @doc """
  Assembles a full prompt string: always-included skills + phase skills + phase prompt.
  Each skill is rendered as `## Skill: <name>\n\n<body>`.
  """
  def assemble_prompt(phase_skills, phase_prompt) do
    skills = always_included() ++ by_identifiers(phase_skills)
    # Deduplicate by identifier in case an always-included skill is also declared in phase
    skills = Enum.uniq_by(skills, & &1.identifier)

    skill_sections =
      Enum.map_join(skills, "\n\n", fn skill ->
        "## Skill: #{skill.name}\n\n#{skill.body}"
      end)

    case skill_sections do
      "" -> phase_prompt
      sections -> sections <> "\n\n" <> phase_prompt
    end
  end

  @doc """
  Returns all parsed skills from priv/skills/.
  """
  def all_skills do
    skills_path = Application.app_dir(:destila, @skills_dir)

    skills_path
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.map(&parse_skill_file/1)
  end

  defp parse_skill_file(path) do
    content = File.read!(path)
    {frontmatter, body} = split_frontmatter(content)

    %{
      identifier: Path.basename(path, ".md"),
      name: parse_field(frontmatter, "name"),
      always: parse_field(frontmatter, "always") == "true",
      body: String.trim(body)
    }
  end

  defp split_frontmatter(content) do
    case Regex.run(~r/\A---\n(.*?)\n---\n(.*)\z/s, content) do
      [_, frontmatter, body] -> {frontmatter, body}
    end
  end

  defp parse_field(frontmatter, field) do
    case Regex.run(~r/^#{field}:\s*(.+)$/m, frontmatter) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end
end
```

**Design decisions:**
- Skills are read from disk on each call. This is simple, correct, and fine for the expected volume (a handful of files read at phase-start time). No caching layer needed.
- The identifier is the filename without `.md` extension (e.g., `asking_questions.md` → `"asking_questions"`).
- Frontmatter parsing uses regex — no new dependencies. The frontmatter is simple `key: value` pairs.
- `assemble_prompt/2` deduplicates by identifier so declaring an always-included skill in a phase's `:skills` list is harmless, not an error.
- `split_frontmatter/1` pattern-matches directly — skill files are our own internal files with known structure, so no defensive error handling needed.

### 2. Add `:skills` field to `Phase` struct

**File:** `lib/destila/workflows/phase.ex:9-15`

Add `skills: []` to the struct definition:

```elixir
defstruct [
  :name,
  :system_prompt,
  non_interactive: false,
  allowed_tools: [],
  session_strategy: :resume,
  skills: []
]
```

### 3. Update `conversation.ex` to assemble prompts with skills

**File:** `lib/destila/ai/conversation.ex:19-28`

Modify `phase_start/1` to read the phase's `:skills` field and call `Skills.assemble_prompt/2`:

```elixir
def phase_start(ws) do
  phase_number = ws.current_phase
  %{system_prompt: prompt_fn, skills: phase_skills} = get_phase(ws, phase_number)

  handle_session_strategy(ws, phase_number)
  ensure_ai_session(ws)
  phase_prompt = prompt_fn.(ws)
  query = Skills.assemble_prompt(phase_skills, phase_prompt)
  enqueue_ai_worker(ws, phase_number, query)
  :processing
end
```

Add the alias at the top of the module (after existing aliases on line 10):

```elixir
alias Destila.Workflows.Skills
```

**Note:** The `skills` key defaults to `[]` in the Phase struct, so all existing phases work without changes. `assemble_prompt([], phase_prompt)` with no always-included skills returns the phase prompt unchanged.

### 4. Create skill files from existing module attributes

Create `priv/skills/` directory and extract the two shared instruction blocks.

#### 4a. `priv/skills/interactive_tool_instructions.md`

Extract from `brainstorm_idea_workflow.ex:45-83`. This is the `@tool_instructions` block used by interactive phases.

```markdown
---
name: Interactive Tool Instructions
always: false
---

## Asking Questions

When asking questions with clear, discrete options, use the
`mcp__destila__ask_user_question` tool to present structured choices.
The tool accepts a `questions` array — batch all your independent questions
in a single call. The user will see clickable buttons for each question.
An 'Other' free-text input is always available automatically — do not include it.

For open-ended questions without clear options, just ask in plain text.

## Phase Transitions

When you believe the current phase's work is complete, call the
`mcp__destila__session` tool. Use the `message` parameter to explain your reasoning.

- Use `action: "suggest_phase_complete"` when you have enough information and want the
user to confirm moving to the next phase.
- Use `action: "phase_complete"` when the phase is definitively not applicable or already
satisfied (e.g., no Gherkin scenarios needed). This auto-advances without user confirmation.

IMPORTANT: Never call `mcp__destila__session` with a phase transition action in the same
response as unanswered questions. If you still need information from the user, ask your
questions and wait for their answers before signaling phase completion.

IMPORTANT: Never call both `mcp__destila__ask_user_question` and `mcp__destila__session`
with a phase transition action in the same response.

## Exporting Data

To store a key-value pair as session metadata, call `mcp__destila__session` with
`action: "export"`, a `key` string, and a `value` string. You may call export
multiple times in a single response and may combine it with a phase transition action.

You can optionally specify a `type` string to indicate how the value should be
interpreted: `text` (default), `text_file` (absolute path to a text file),
`markdown` (markdown content), or `video_file` (absolute path to a video file).
```

#### 4b. `priv/skills/non_interactive_tool_instructions.md`

Extract from `implement_general_prompt_workflow.ex:36-55`.

```markdown
---
name: Non-Interactive Tool Instructions
always: false
---

## Phase Transitions

When you have completed this phase's work, call `mcp__destila__session`
with `action: "phase_complete"` and a `message` summarizing what was done.

Do NOT use `suggest_phase_complete` — this phase runs autonomously.
Do NOT call `mcp__destila__ask_user_question` — no user is present.

## Exporting Data

To store a key-value pair as session metadata, call `mcp__destila__session` with
`action: "export"`, a `key` string, and a `value` string. You may call export
multiple times in a single response and may combine it with a phase transition action.

You can optionally specify a `type` string to indicate how the value should be
interpreted: `text` (default), `text_file` (absolute path to a text file),
`markdown` (markdown content), or `video_file` (absolute path to a video file).
```

### 5. Migrate workflow modules to use skills

#### 5a. `brainstorm_idea_workflow.ex`

- Remove the `@tool_instructions` module attribute (lines 45-83)
- Add `skills: ["interactive_tool_instructions"]` to phases that currently append `@tool_instructions`:
  - Task Description phase
  - Gherkin Review phase
  - Technical Concerns phase
- Remove `<> @tool_instructions` from the prompt functions: `task_description_prompt/1`, `gherkin_review_prompt/1`, `technical_concerns_prompt/1`
- Prompt Generation phase has no `@tool_instructions` — leave unchanged, no skills needed

After migration:

```elixir
def phases do
  [
    %Phase{name: "Task Description", system_prompt: &task_description_prompt/1,
           skills: ["interactive_tool_instructions"]},
    %Phase{name: "Gherkin Review", system_prompt: &gherkin_review_prompt/1,
           skills: ["interactive_tool_instructions"]},
    %Phase{name: "Technical Concerns", system_prompt: &technical_concerns_prompt/1,
           skills: ["interactive_tool_instructions"]},
    %Phase{name: "Prompt Generation", system_prompt: &prompt_generation_prompt/1}
  ]
end
```

#### 5b. `implement_general_prompt_workflow.ex`

- Remove the `@non_interactive_tool_instructions` module attribute (lines 36-55)
- Add `skills: ["non_interactive_tool_instructions"]` to all non-interactive phases (Generate Plan through Feature Video)
- Remove `<> @non_interactive_tool_instructions` from all prompt functions that use it: `plan_prompt/1`, `deepen_plan_prompt/1`, `work_prompt/1`, `review_prompt/1`, `browser_tests_prompt/1`, `feature_video_prompt/1`
- Adjustments phase (interactive, no `@non_interactive_tool_instructions`) — leave unchanged

After migration:

```elixir
def phases do
  [
    %Phase{name: "Generate Plan", system_prompt: &plan_prompt/1,
           non_interactive: true, allowed_tools: @implementation_tools,
           skills: ["non_interactive_tool_instructions"]},
    %Phase{name: "Deepen Plan", system_prompt: &deepen_plan_prompt/1,
           non_interactive: true, allowed_tools: @implementation_tools,
           skills: ["non_interactive_tool_instructions"]},
    %Phase{name: "Work", system_prompt: &work_prompt/1,
           non_interactive: true, allowed_tools: @implementation_tools,
           session_strategy: :new,
           skills: ["non_interactive_tool_instructions"]},
    %Phase{name: "Review", system_prompt: &review_prompt/1,
           non_interactive: true, allowed_tools: @implementation_tools,
           skills: ["non_interactive_tool_instructions"]},
    %Phase{name: "Browser Tests", system_prompt: &browser_tests_prompt/1,
           non_interactive: true, allowed_tools: @implementation_tools,
           skills: ["non_interactive_tool_instructions"]},
    %Phase{name: "Feature Video", system_prompt: &feature_video_prompt/1,
           non_interactive: true, allowed_tools: @implementation_tools,
           skills: ["non_interactive_tool_instructions"]},
    %Phase{name: "Adjustments", system_prompt: &adjustments_prompt/1,
           allowed_tools: @implementation_tools}
  ]
end
```

#### 5c. `code_chat_workflow.ex`

This workflow inlines its tool instructions directly in the prompt function rather than using a module attribute. Leave it as-is — the instructions are specific enough to this workflow that extracting them wouldn't provide reuse value. The skills system is available if future chat-related workflows need shared instructions.

### 6. Write tests

**File:** `test/destila/workflows/skills_test.exs`

```elixir
defmodule Destila.Workflows.SkillsTest do
  use ExUnit.Case, async: true

  alias Destila.Workflows.Skills

  # Tests use the actual skill files in priv/skills/ that we create in this feature.
  # This validates real file discovery and parsing end-to-end.

  describe "all_skills/0" do
    test "discovers skill files from priv/skills/" do
      skills = Skills.all_skills()
      identifiers = Enum.map(skills, & &1.identifier)
      assert "interactive_tool_instructions" in identifiers
      assert "non_interactive_tool_instructions" in identifiers
    end

    test "parses name from frontmatter" do
      skill = Skills.all_skills() |> Enum.find(&(&1.identifier == "interactive_tool_instructions"))
      assert skill.name == "Interactive Tool Instructions"
    end

    test "parses always field from frontmatter" do
      skill = Skills.all_skills() |> Enum.find(&(&1.identifier == "interactive_tool_instructions"))
      assert skill.always == false
    end

    test "parses body content after frontmatter" do
      skill = Skills.all_skills() |> Enum.find(&(&1.identifier == "interactive_tool_instructions"))
      assert skill.body =~ "Asking Questions"
      assert skill.body =~ "mcp__destila__ask_user_question"
    end
  end

  describe "always_included/0" do
    test "returns only skills with always: true" do
      skills = Skills.always_included()
      assert Enum.all?(skills, & &1.always)
    end
  end

  describe "by_identifiers/1" do
    test "returns skills matching given identifiers" do
      skills = Skills.by_identifiers(["interactive_tool_instructions"])
      assert length(skills) == 1
      assert hd(skills).identifier == "interactive_tool_instructions"
    end

    test "returns empty list for unknown identifiers" do
      assert Skills.by_identifiers(["nonexistent"]) == []
    end
  end

  describe "assemble_prompt/2" do
    test "prepends skill sections before phase prompt" do
      result = Skills.assemble_prompt(["interactive_tool_instructions"], "Do the task.")
      assert result =~ "## Skill: Interactive Tool Instructions"
      # Phase prompt comes after skills
      assert result |> String.split("Do the task.") |> length() == 2
    end

    test "returns phase prompt unchanged when no skills apply" do
      # Assumes no always: true skills exist yet; if they do, this test
      # would need adjustment
      result = Skills.assemble_prompt([], "Do the task.")
      # The result should end with the phase prompt
      assert String.ends_with?(result, "Do the task.")
    end

    test "deduplicates skills by identifier" do
      # Request a skill that might also be always-included
      result = Skills.assemble_prompt(
        ["interactive_tool_instructions", "interactive_tool_instructions"],
        "Do the task."
      )
      occurrences =
        result
        |> String.split("## Skill: Interactive Tool Instructions")
        |> length()

      # Should appear exactly once (2 parts = 1 occurrence)
      assert occurrences == 2
    end

    test "renders each skill with correct heading format" do
      result = Skills.assemble_prompt(["non_interactive_tool_instructions"], "Task.")
      assert result =~ "## Skill: Non-Interactive Tool Instructions\n\n"
    end
  end
end
```

Tests use the actual skill files created in step 4, validating the full discovery-parse-assemble pipeline end-to-end.

## Files to create

| File | Purpose |
|------|---------|
| `lib/destila/workflows/skills.ex` | Skills module: discovery, parsing, assembly |
| `priv/skills/interactive_tool_instructions.md` | Extracted from `@tool_instructions` |
| `priv/skills/non_interactive_tool_instructions.md` | Extracted from `@non_interactive_tool_instructions` |
| `test/destila/workflows/skills_test.exs` | Unit tests for the skills module |

## Files to modify

| File | Change |
|------|--------|
| `lib/destila/workflows/phase.ex` | Add `skills: []` to struct |
| `lib/destila/ai/conversation.ex` | Add Skills alias, update `phase_start/1` to call `assemble_prompt/2` |
| `lib/destila/workflows/brainstorm_idea_workflow.ex` | Remove `@tool_instructions`, add `skills:` to phases, remove `<>` concatenation |
| `lib/destila/workflows/implement_general_prompt_workflow.ex` | Remove `@non_interactive_tool_instructions`, add `skills:` to phases, remove `<>` concatenation |

## Implementation order

1. Create `priv/skills/` directory and skill files (steps 4a, 4b)
2. Create `skills.ex` module (step 1)
3. Add `:skills` field to Phase struct (step 2)
4. Update `conversation.ex` prompt assembly (step 3)
5. Create tests and verify they pass (step 6)
6. Migrate `brainstorm_idea_workflow.ex` (step 5a)
7. Migrate `implement_general_prompt_workflow.ex` (step 5b)
8. Run full test suite to verify no regressions
