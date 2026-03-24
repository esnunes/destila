defmodule Destila.Workflows.ChoreTaskPhases do
  @moduledoc """
  Defines AI system prompts and phase metadata for the Chore/Task workflow.

  Each phase is a multi-turn AI conversation. The AI uses markers to signal
  phase transitions:
  - `<<READY_TO_ADVANCE>>` — AI suggests advancing to the next phase
  - `<<SKIP_PHASE>>` — AI determines phase can be skipped (Phase 2 only)
  """

  @phase_names %{
    0 => "Setup",
    1 => "Task Description",
    2 => "Gherkin Review",
    3 => "Technical Concerns",
    4 => "Prompt Generation"
  }

  @doc """
  Returns the human-readable name for a phase number.
  """
  def phase_name(phase) when is_map_key(@phase_names, phase) do
    @phase_names[phase]
  end

  def phase_name(_phase), do: nil

  @tool_instructions """

  ## Asking Questions

  When asking questions with clear, discrete options, use the \
  `mcp__destila__ask_user_question` tool to present structured choices. \
  The tool accepts a `questions` array — batch all your independent questions \
  in a single call. The user will see clickable buttons for each question. \
  An 'Other' free-text input is always available automatically — do not include it.

  For open-ended questions without clear options, just ask in plain text.
  """

  @doc """
  Returns the AI system prompt for a given phase and workflow session context.
  """
  def system_prompt(1, _workflow_session) do
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
    of the task, end your message with <<READY_TO_ADVANCE>>
    """ <> @tool_instructions
  end

  def system_prompt(2, workflow_session) do
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

    Use your tools to browse the repository and find existing .feature files. Then:

    1. If .feature files exist, review them against the task discussed.
       - If changes are needed, propose specific additions, modifications, or removals.
       - Discuss with the user until they agree on the changes.
       - When done, end your message with <<READY_TO_ADVANCE>>

    2. If no .feature files exist in the repository:
       - Ask the user if they want to define new Gherkin scenarios for this task.
       - If yes, help them draft scenarios and end with <<READY_TO_ADVANCE>>
       - If no, end your message with <<SKIP_PHASE>>

    3. If the task doesn't require Gherkin changes:
       - Explain why and end your message with <<SKIP_PHASE>>
    """ <> @tool_instructions
  end

  def system_prompt(3, _workflow_session) do
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

    When the technical approach is sufficiently clear, \
    end your message with <<READY_TO_ADVANCE>>
    """ <> @tool_instructions
  end

  def system_prompt(4, _workflow_session) do
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

    Present the prompt clearly. The user may ask you to refine it. \
    Do NOT end with <<READY_TO_ADVANCE>> — the user will mark this as done when satisfied.
    """
  end

  @doc """
  Builds a conversation context string from existing messages for session resumption.
  Groups messages by phase and summarizes each.
  """
  def build_conversation_context(messages) do
    messages
    |> Enum.group_by(& &1.phase)
    |> Enum.sort_by(fn {phase, _} -> phase end)
    |> Enum.map(fn {phase, msgs} ->
      phase_label = phase_name(phase) || "Phase #{phase}"

      content =
        msgs
        |> Enum.map(fn msg ->
          role = if msg.role == :user, do: "User", else: "Assistant"
          "#{role}: #{msg.content}"
        end)
        |> Enum.join("\n")

      "## #{phase_label}\n#{content}"
    end)
    |> Enum.join("\n\n")
  end
end
