defmodule Destila.Workflows.BrainstormIdeaWorkflow do
  @moduledoc """
  Defines the Brainstorm Idea workflow — an AI-driven multi-phase conversation
  that clarifies a coding task and produces an implementation prompt.

  Phases:
  1. Task Description — AI asks clarifying questions about the task
  2. Gherkin Review — AI reviews or proposes BDD feature scenarios (skippable)
  3. Technical Concerns — AI explores technical approach and trade-offs
  4. Prompt Generation — AI generates the final implementation prompt

  Session creation and setup are handled by CreateSessionLive before the session
  reaches WorkflowRunnerLive.
  """

  use Destila.Workflows.Workflow

  alias Destila.Workflows.Phase

  def phases do
    [
      %Phase{name: "Task Description", system_prompt: &task_description_prompt/1},
      %Phase{name: "Gherkin Review", system_prompt: &gherkin_review_prompt/1},
      %Phase{name: "Technical Concerns", system_prompt: &technical_concerns_prompt/1},
      %Phase{
        name: "Prompt Generation",
        system_prompt: &prompt_generation_prompt/1,
        message_type: :generated_prompt
      }
    ]
  end

  def creation_config, do: {nil, "Idea", "idea"}

  def default_title, do: "New Idea"

  def label, do: "Brainstorm Idea"
  def description, do: "Straightforward coding tasks, bug fixes, or refactors"
  def icon, do: "hero-wrench-screwdriver"
  def icon_class, do: "text-warning"

  def completion_message do
    "Your implementation prompt is ready! The task has been clarified, the technical approach defined, and Gherkin scenarios reviewed."
  end

  # --- AI system prompts ---

  @tool_instructions """

  ## Asking Questions

  When asking questions with clear, discrete options, use the \
  `mcp__destila__ask_user_question` tool to present structured choices. \
  The tool accepts a `questions` array — batch all your independent questions \
  in a single call. The user will see clickable buttons for each question. \
  An 'Other' free-text input is always available automatically — do not include it.

  For open-ended questions without clear options, just ask in plain text.

  ## Phase Transitions

  When you believe the current phase's work is complete, call the \
  `mcp__destila__session` tool. Use the `message` parameter to explain your reasoning.

  - Use `action: "suggest_phase_complete"` when you have enough information and want the \
  user to confirm moving to the next phase.
  - Use `action: "phase_complete"` when the phase is definitively not applicable or already \
  satisfied (e.g., no Gherkin scenarios needed). This auto-advances without user confirmation.

  IMPORTANT: Never call `mcp__destila__session` with a phase transition action in the same \
  response as unanswered questions. If you still need information from the user, ask your \
  questions and wait for their answers before signaling phase completion.

  IMPORTANT: Never call both `mcp__destila__ask_user_question` and `mcp__destila__session` \
  with a phase transition action in the same response.

  ## Exporting Data

  To store a key-value pair as session metadata, call `mcp__destila__session` with \
  `action: "export"`, a `key` string, and a `value` string. You may call export \
  multiple times in a single response and may combine it with a phase transition action.
  """

  defp task_description_prompt(workflow_session) do
    metadata = Destila.Workflows.get_metadata(workflow_session.id)
    idea = get_in(metadata, ["idea", "text"])

    idea_context =
      if idea && idea != "" do
        "\n\nThe user's initial idea:\n#{idea}"
      else
        ""
      end

    """
    You are helping clarify a coding task. The user has described their initial idea. \
    Your job is to ask focused questions to understand exactly what they want and how it should work.

    Focus on:
    - What the expected behavior should be
    - What the current behavior is (if it's a fix)
    - Edge cases or constraints
    - Who or what is affected
    - Use codebase knowledge to ask better questions, but do not include implementation \
      details - technical details will be gathered in a later step

    You may batch multiple independent questions in a single response when their answers \
    do not depend on each other. Never batch questions where the answer to one would change \
    the options of another.

    Keep your questions concise and specific. When you believe you have a clear understanding \
    of the task, call the `mcp__destila__session` tool with `action: "suggest_phase_complete"` \
    and a message summarizing your understanding.
    """ <> @tool_instructions <> idea_context
  end

  defp gherkin_review_prompt(workflow_session) do
    project =
      if workflow_session.project_id,
        do: Destila.Projects.get_project(workflow_session.project_id)

    repo_context =
      cond do
        project && project.git_repo_url && project.local_folder ->
          "The project \"#{project.name}\" has a git repository at #{project.git_repo_url} and a local folder at #{project.local_folder}."

        project && project.git_repo_url ->
          "The project \"#{project.name}\" has a git repository at #{project.git_repo_url}."

        project && project.local_folder ->
          "The project \"#{project.name}\" has a local folder at #{project.local_folder}."

        true ->
          "The repository location is unknown."
      end

    """
    You are reviewing Gherkin feature files for a coding task. #{repo_context}

    IMPORTANT: This phase is review and discussion only. Do NOT modify any files. \
    Your role is to propose Gherkin scenario text in your messages for the user to review. \
    The actual file changes will happen later during implementation.

    Use your tools to browse the repository and find existing .feature files. Then:

    1. If .feature files exist, review them against the task discussed.
       - If changes are needed, propose specific additions, modifications, or removals \
         in your message text.
       - Discuss with the user until they agree on the changes.
       - When done, call `mcp__destila__session` with `action: "suggest_phase_complete"`.

    2. If no .feature files exist in the repository:
       - Ask the user if they want to define new Gherkin scenarios for this task.
       - If yes, help them draft scenarios in your message text and call \
         `mcp__destila__session` with `action: "suggest_phase_complete"`.
       - If no, call `mcp__destila__session` with `action: "phase_complete"` and a \
         message explaining why.

    3. If the task doesn't require Gherkin changes:
       - Call `mcp__destila__session` with `action: "phase_complete"` and a \
         message explaining why.
    """ <> @tool_instructions
  end

  defp technical_concerns_prompt(_workflow_session) do
    """
    You are exploring technical concerns for a coding task. Based on the prior conversation, \
    ask about the technical approach to implementing this task.

    Focus on:
    - Architecture or design patterns to follow
    - Potential breaking changes or risks
    - Dependencies or integrations affected
    - Testing strategy

    You may batch multiple independent questions in a single response when their answers \
    do not depend on each other. Never batch questions where the answer to one would change \
    the options of another.

    When the technical approach is sufficiently clear, call the `mcp__destila__session` \
    tool with `action: "suggest_phase_complete"` and a message summarizing the agreed approach.
    """ <> @tool_instructions
  end

  defp prompt_generation_prompt(_workflow_session) do
    """
    Generate a high-level implementation prompt based on the entire conversation so far. \
    This prompt should be ready to hand to a developer or coding agent.

    The prompt should include:
    - A clear description of what needs to be done
    - The technical approach to take
    - Any Gherkin scenarios that were discussed
    - Constraints and edge cases to handle

    The prompt should NOT include:
    - Detailed task lists or step-by-step instructions
    - Database schema designs
    - File-by-file change lists
    - Time estimates

    IMPORTANT: Output ONLY the prompt itself — no introductory text, headers, footers, \
    or commentary around it. Do not wrap it in a code block. Do not say "Here is the prompt:" \
    or "Let me know if you'd like changes." Just the prompt content, nothing else.

    After outputting the prompt, call `mcp__destila__session` with `action: "export"`, \
    `key: "prompt_generated"`, and `value` set to the full prompt text you just generated.

    The user may ask you to refine it. Each time you output a revised prompt, export it again \
    with the same key to update the stored value.

    Do NOT call the `mcp__destila__session` tool with `suggest_phase_complete` or \
    `phase_complete` — the user will mark this phase as done manually.
    """
  end
end
