defmodule Destila.AI.Tools do
  @moduledoc """
  MCP tool server for Destila AI sessions.

  Provides structured interaction tools that the AI can call during conversations.
  """

  use ClaudeCode.MCP.Server, name: "destila"

  tool :ask_user_question,
       "Present one or more structured questions to the user with selectable options. " <>
         "Use this when you want the user to choose from specific options. " <>
         "The user will see the options as clickable buttons. " <>
         "An 'Other' free-text option is always available automatically — do not include it. " <>
         "You may batch multiple independent questions in a single call." do
    field(
      :questions,
      {:list,
       %{
         title: {:required, :string},
         question: {:required, :string},
         multi_select: {:required, :boolean},
         options:
           {:required,
            {:list,
             %{
               label: {:required, :string},
               description: {:required, :string}
             }}}
       }},
      required: true,
      description:
        "Array of questions. Each has a title (max 12 chars), question text, " <>
          "multi_select (true=checkboxes, false=radio), and 2-4 options with label and description"
    )

    def execute(_params) do
      {:ok, "Questions presented to the user. Stop here and wait for their response."}
    end
  end

  @doc """
  Returns prompt instructions for Destila tools based on the phase mode.

  `:interactive` — for phases where the user is present and can confirm transitions.
  `:non_interactive` — for autonomous phases that auto-advance.
  """
  def prompt_instructions(:interactive) do
    """

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

    You can optionally specify a `type` string to indicate how the value should be \
    interpreted: `text` (default), `text_file` (absolute path to a text file), \
    `markdown` (markdown content), or `video_file` (absolute path to a video file).
    """
  end

  def prompt_instructions(:non_interactive) do
    """

    ## Phase Transitions

    When you have completed this phase's work, call `mcp__destila__session` \
    with `action: "phase_complete"` and a `message` summarizing what was done.

    Do NOT use `suggest_phase_complete` — this phase runs autonomously.
    Do NOT call `mcp__destila__ask_user_question` — no user is present.

    ## Exporting Data

    To store a key-value pair as session metadata, call `mcp__destila__session` with \
    `action: "export"`, a `key` string, and a `value` string. You may call export \
    multiple times in a single response and may combine it with a phase transition action.

    You can optionally specify a `type` string to indicate how the value should be \
    interpreted: `text` (default), `text_file` (absolute path to a text file), \
    `markdown` (markdown content), or `video_file` (absolute path to a video file).
    """
  end

  tool :session,
       "Signal a phase transition or export metadata in the workflow session. " <>
         "Call this tool to advance phases or store key-value outputs." do
    field(:action, :string,
      required: true,
      description:
        "One of: suggest_phase_complete (phase work is done, ask user to confirm), " <>
          "phase_complete (phase is definitively done or not applicable, auto-advance), " <>
          "export (store a key-value pair as exported session metadata)"
    )

    field(:message, :string,
      description:
        "Context or reason for the action. Required for suggest_phase_complete and phase_complete."
    )

    field(:key, :string,
      description:
        "Metadata key for the export action, e.g. 'prompt_generated'. Required for export."
    )

    field(:value, :string,
      description: "Metadata value for the export action. Required for export."
    )

    field(:type, :string,
      description:
        "Type of the exported value. One of: text (default), text_file, markdown, video_file. " <>
          "Determines how the value is interpreted and rendered."
    )

    def execute(_params) do
      {:ok, "Action recorded."}
    end
  end
end
