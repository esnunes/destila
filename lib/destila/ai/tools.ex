defmodule Destila.AI.Tools do
  @moduledoc """
  MCP tool server for Destila AI sessions.

  Provides structured interaction tools that the AI can call during conversations.
  """

  use ClaudeCode.MCP.Server, name: "destila"

  tool :ask_user_question do
    description(
      "Present one or more structured questions to the user with selectable options. Use this when you want the user to choose from specific options."
    )

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

  @ask_user_question_details """
  ## Asking Questions

  When asking questions with clear, discrete options, use the \
  `mcp__destila__ask_user_question` tool to present structured choices. \
  The tool accepts a `questions` array — batch all your independent questions \
  in a single call. The user will see clickable buttons for each question. \
  An 'Other' free-text input is always available automatically — do not include it.

  You may batch multiple independent questions in a single response when their answers \
  do not depend on each other. Never batch questions where the answer to one would change \
  the options of another.

  For open-ended questions without clear options, just ask in plain text.

  IMPORTANT: Never call `mcp__destila__ask_user_question` with a phase transition \
  action in the same response.
  """

  tool :session do
    description(
      "Signal a phase transition or export metadata in the workflow session. Call this tool to advance phases or store key-value outputs."
    )

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

  @session_details """
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

  ## Exporting Data

  To store a key-value pair as session metadata, call `mcp__destila__session` with \
  `action: "export"`, a `key` string, and a `value` string. You may call export \
  multiple times in a single response and may combine it with a phase transition action.

  You can optionally specify a `type` string to indicate how the value should be \
  interpreted: `text` (default), `text_file` (absolute path to a text file), \
  `markdown` (markdown content), or `video_file` (absolute path to a video file).
  """

  tool :service do
    description(
      "Manage the project's development service lifecycle. Use this to start, stop, restart, or check the status of the project's service."
    )

    field(:action, :string,
      required: true,
      description:
        "One of: start (start the service), stop (stop the service), " <>
          "restart (restart the service), status (check current service status)"
    )

    def execute(%{action: action}, frame) do
      try do
        workflow_session_id = frame.assigns[:workflow_session_id]
        ws = Destila.Workflows.get_workflow_session!(workflow_session_id)
        ai_session = Destila.AI.get_ai_session_for_workflow(ws.id)
        worktree_path = ai_session && ai_session.worktree_path

        case Destila.Services.ServiceManager.execute(ws, action, worktree_path: worktree_path) do
          {:ok, state} -> {:ok, Jason.encode!(state)}
          {:error, reason} -> {:ok, "Service error: #{reason}"}
        end
      rescue
        e -> {:ok, "Service error: #{Exception.message(e)}"}
      end
    end
  end

  @service_details """
  ## Service Management

  Use the `mcp__destila__service` tool to manage the project's development server. \
  The tool accepts an `action` parameter:

  - `start` — Start the service using the project's configured run command. \
  Returns the assigned port mappings (e.g., `{"PORT": 54321}`).
  - `stop` — Stop the running service gracefully.
  - `restart` — Stop and restart the service with fresh port assignments.
  - `status` — Check the current service status and port mappings.

  The tool result contains the service state as JSON, including status and \
  port mappings. Use these ports when configuring or accessing the service.
  """

  @tool_descriptions %{
    "mcp__destila__ask_user_question" => @ask_user_question_details,
    "mcp__destila__session" => @session_details,
    "mcp__destila__service" => @service_details
  }

  @doc """
  Returns assembled prompt descriptions for the given tool names.
  Only includes descriptions for Destila custom tools.
  """
  def tool_descriptions(tool_names) do
    tool_names
    |> Enum.filter(&Map.has_key?(@tool_descriptions, &1))
    |> Enum.map_join("\n", &@tool_descriptions[&1])
  end

  @doc """
  Returns the names of all Destila tools that have prompt descriptions.
  Used as fallback when a phase has no explicit `allowed_tools`.
  """
  def described_tool_names, do: Map.keys(@tool_descriptions)
end
