defmodule Destila.AI.Conversation do
  @moduledoc """
  Handles all AI conversation mechanics -- phase starts, user messages,
  AI results, and AI errors.

  SessionProcess calls this module directly instead of delegating to workflow
  modules. Workflow modules remain purely declarative.
  """

  alias Destila.{AI, Workflows}
  alias Destila.AI.ResponseProcessor
  alias Destila.Workflows.Skills

  @doc """
  Starts a phase by cutting a new AI session when the phase crosses an
  `AISessionGroup` boundary, ensuring an AI session exists, assembling the
  kickoff body, and enqueuing the AI worker.

  Returns `:processing`.
  """
  def phase_start(ws) do
    phase_number = ws.current_phase

    %{
      initial_prompt: prompt_fn,
      skills: phase_skills,
      non_interactive: non_interactive
    } = get_phase(ws, phase_number)

    group = Workflows.group_for_phase(ws.workflow_type, phase_number)

    ensure_ai_session(ws, phase_number, group)
    phase_prompt = prompt_fn.(ws)

    body_skills =
      if non_interactive,
        do: Enum.uniq(["non_interactive" | phase_skills]),
        else: phase_skills

    skills_extra = Skills.assemble_skills_excluding(body_skills, group.skills)
    service_section = build_service_section(ws)

    sections = [
      service_section,
      if(skills_extra != "", do: "# Skills (additional)\n\n#{skills_extra}"),
      "# Prompt\n\n#{phase_prompt}"
    ]

    query = sections |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")

    enqueue_ai_worker(ws, phase_number, query)
    :processing
  end

  @doc """
  Sends a user message for the current phase.

  Returns `:processing`.
  """
  def send_message(ws, message) do
    phase_number = ws.current_phase
    ai_session = AI.get_ai_session_for_workflow!(ws.id)

    AI.create_message(ai_session.id, %{
      role: :user,
      content: message,
      phase: phase_number,
      workflow_session_id: ws.id
    })

    enqueue_ai_worker(ws, phase_number, message)
    :processing
  end

  @doc """
  Processes an AI result for the current phase.

  Returns `:awaiting_input`, `:phase_complete`, or `:suggest_phase_complete`.

  For non-interactive phases, a completed turn with no explicit session action
  auto-advances to `:phase_complete`. This avoids getting stuck when context
  compaction hides the original phase prompt (which describes how to signal
  completion) from the agent.
  """
  def handle_ai_result(ws, result) do
    phase_number = ws.current_phase
    ai_session = AI.get_ai_session_for_workflow!(ws.id)
    %{non_interactive: non_interactive} = get_phase(ws, phase_number)

    response_text = ResponseProcessor.response_text(result)
    session_action = ResponseProcessor.extract_session_action(result)

    content =
      case session_action do
        %{message: msg} when is_binary(msg) and msg != "" -> msg
        _ -> response_text
      end

    AI.create_message(ai_session.id, %{
      role: :system,
      content: content,
      raw_response: result,
      phase: phase_number,
      workflow_session_id: ws.id
    })

    if result[:session_id] do
      AI.update_ai_session(ai_session, %{claude_session_id: result[:session_id]})
    end

    # Process export actions
    export_actions = ResponseProcessor.extract_export_actions(result)

    if export_actions != [] do
      phase_name =
        Workflows.phase_name(ws.workflow_type, phase_number) || "Phase #{phase_number}"

      valid_types = Workflows.valid_metadata_types()

      for %{key: key, value: value, type: type} <- export_actions,
          key != nil,
          type = type || "text",
          type in valid_types do
        Workflows.upsert_metadata(
          ws.id,
          phase_name,
          key,
          %{type => value},
          exported: true
        )
      end
    end

    case session_action do
      %{action: "phase_complete"} -> :phase_complete
      %{action: "suggest_phase_complete"} -> :suggest_phase_complete
      _ when non_interactive -> :phase_complete
      _ -> :awaiting_input
    end
  end

  @doc """
  Handles an AI error for the current phase.

  Returns `:awaiting_input`.
  """
  def handle_ai_error(ws, reason) do
    phase_number = ws.current_phase
    ai_session = AI.get_ai_session_for_workflow!(ws.id)

    AI.create_message(ai_session.id, %{
      role: :system,
      content: error_message(reason),
      phase: phase_number,
      workflow_session_id: ws.id
    })

    :awaiting_input
  end

  defp error_message(%{auth_error: auth_error}) when is_binary(auth_error) do
    auth_failed_message(auth_error)
  end

  defp error_message(reason) do
    text = extract_error_text(reason)

    cond do
      text != "" && authentication_error?(text) ->
        auth_failed_message(text)

      text != "" ->
        "Something went wrong: #{text}"

      true ->
        "Something went wrong. Please try sending your message again."
    end
  end

  defp auth_failed_message(detail) do
    "Claude authentication failed: #{detail}. " <>
      "Please run `claude login` in your terminal to re-authenticate, then retry."
  end

  defp authentication_error?(text) do
    downcased = String.downcase(text)

    String.contains?(downcased, "authentication_error") or
      String.contains?(downcased, "invalid authentication") or
      (String.contains?(downcased, "401") and String.contains?(downcased, "authenticate"))
  end

  defp extract_error_text(%{errors: [_ | _] = errors}), do: Enum.join(errors, "; ")
  defp extract_error_text(%{result: result}) when is_binary(result), do: result
  defp extract_error_text(%{text: text}) when is_binary(text) and text != "", do: text

  defp extract_error_text({:provisioning_failed, {:initialize_failed, msg}})
       when is_binary(msg),
       do: msg

  defp extract_error_text({:provisioning_failed, {:cli_exit, status}}),
    do: "Claude CLI exited unexpectedly (exit code #{status})"

  defp extract_error_text({:provisioning_failed, :initialize_timeout}),
    do: "Claude CLI timed out during initialization"

  defp extract_error_text({:provisioning_failed, reason}),
    do: extract_error_text(reason)

  defp extract_error_text({:plugin_setup_failed, reason}) when is_binary(reason), do: reason

  defp extract_error_text({:cli_not_found, msg}) when is_binary(msg), do: msg

  defp extract_error_text(reason) when is_binary(reason), do: reason
  defp extract_error_text(_), do: ""

  # --- Private ---

  # Ensures the workflow session has a live `AI.Session` for the current
  # phase's group. Creates a fresh session on the first phase_start (bootstrap)
  # and when the phase crosses into a new group (carrying worktree_path forward
  # and stopping any stale ClaudeSession). Otherwise the existing session is
  # reused, which keeps phase-1 retries and same-group advances idempotent.
  defp ensure_ai_session(ws, phase_number, group) do
    current_session = AI.get_ai_session_for_workflow(ws.id)

    prev_group =
      if phase_number > 1 do
        Workflows.group_for_phase(ws.workflow_type, phase_number - 1)
      end

    if is_nil(current_session) or (phase_number > 1 and group != prev_group) do
      # Create the fresh AI.Session before stopping the old ClaudeSession so a
      # failed insert leaves the previous session intact instead of a half-cut
      # state (ClaudeSession stopped, DB still pointing at the stale row).
      {:ok, _session} =
        AI.create_ai_session(%{
          workflow_session_id: ws.id,
          worktree_path: current_session && current_session.worktree_path
        })

      AI.ClaudeSession.stop_for_workflow_session(ws.id)
    end

    :ok
  end

  defp build_service_section(%{service_state: nil}), do: nil

  defp build_service_section(%{service_state: state}) do
    status = state["status"]

    url_info =
      case state["port"] do
        port when is_integer(port) -> "\nURL: http://localhost:#{port}"
        _ -> ""
      end

    "# Service Status\n\nThe project service is currently #{status}.#{url_info}"
  end

  defp get_phase(ws, phase_number) do
    Enum.at(Workflows.phases(ws.workflow_type), phase_number - 1)
  end

  defp enqueue_ai_worker(ws, phase, query) do
    %{"workflow_session_id" => ws.id, "phase" => phase, "query" => query}
    |> Destila.Workers.AiQueryWorker.new()
    |> Oban.insert()
  end
end
