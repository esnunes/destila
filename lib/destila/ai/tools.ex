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
end
