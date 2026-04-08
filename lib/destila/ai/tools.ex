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
