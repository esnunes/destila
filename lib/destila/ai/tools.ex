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
        "Type of the exported value. One of: text (default), markdown, file. " <>
          "Determines how the value is interpreted and rendered."
    )

    def execute(_params) do
      {:ok, "Action recorded."}
    end
  end

  tool :service do
    description(
      "Manage the project's development service lifecycle (start/stop/restart/status). Requires the project to be configured as a webservice (a run command and a service env var name)."
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
          {:ok, state} -> {:ok, Jason.encode!(Destila.AI.Tools.service_state_to_output(state))}
          {:error, reason} -> {:ok, "Service error: #{reason}"}
        end
      rescue
        e -> {:ok, "Service error: #{Exception.message(e)}"}
      end
    end
  end

  @doc false
  def service_state_to_output(state) do
    base = %{
      "status" => state["status"],
      "run_command" => state["run_command"],
      "setup_command" => state["setup_command"]
    }

    case state["port"] do
      port when is_integer(port) -> Map.put(base, "url", "http://localhost:#{port}")
      _ -> base
    end
  end
end
