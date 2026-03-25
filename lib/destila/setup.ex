defmodule Destila.Setup do
  @moduledoc """
  Coordinates Phase 0 completion between TitleGenerationWorker and SetupWorker.

  Both workers call `maybe_finish_phase0/1` after completing. This module
  uses an atomic compare-and-swap to ensure exactly one worker triggers
  the Phase 1 transition.
  """

  import Ecto.Query

  alias Destila.{Messages, Repo}
  alias Destila.WorkflowSessions.WorkflowSession

  @doc """
  Checks if Phase 0 setup is fully complete (both title generation and setup steps)
  and if so, atomically transitions the workflow session to :generating and triggers Phase 1.

  Returns :ok if Phase 1 was triggered, :noop otherwise.
  """
  def maybe_finish_phase0(workflow_session_id) do
    workflow_session = Destila.WorkflowSessions.get_workflow_session!(workflow_session_id)

    if workflow_session.phase_status != :setup do
      :noop
    else
      phase0_messages =
        Messages.list_messages(workflow_session_id)
        |> Enum.filter(&(&1.phase == 0))

      title_done = step_completed?(phase0_messages, "title_generation")

      setup_done =
        if workflow_session.project_id do
          step_completed?(phase0_messages, "ai_session")
        else
          true
        end

      if title_done && setup_done do
        # Atomic compare-and-swap: only one worker wins
        {count, _} =
          from(ws in WorkflowSession,
            where: ws.id == ^workflow_session_id and ws.phase_status == :setup
          )
          |> Repo.update_all(set: [phase_status: :generating])

        if count == 1 do
          trigger_phase1(workflow_session)
          :ok
        else
          :noop
        end
      else
        :noop
      end
    end
  end

  defp step_completed?(phase0_messages, step_name) do
    Enum.any?(phase0_messages, fn msg ->
      msg.raw_response &&
        msg.raw_response["setup_step"] == step_name &&
        msg.raw_response["status"] == "completed"
    end)
  end

  defp trigger_phase1(workflow_session) do
    phase = 1

    # Filter out phase 0 messages — they're setup noise, not conversation context
    messages =
      Messages.list_messages(workflow_session.id)
      |> Enum.filter(&(&1.phase > 0))

    workflow_module = Destila.Workflows.workflow_module(workflow_session.workflow_type)
    system_prompt = workflow_module.system_prompt(phase, workflow_session)
    context = workflow_module.build_conversation_context(messages)
    query = system_prompt <> "\n\n" <> context

    # Broadcast the update so LiveView picks up the :generating status
    workflow_session = Destila.WorkflowSessions.get_workflow_session!(workflow_session.id)
    Destila.PubSubHelper.broadcast_event(:workflow_session_updated, workflow_session)

    %{"workflow_session_id" => workflow_session.id, "phase" => phase, "query" => query}
    |> Destila.Workers.AiQueryWorker.new()
    |> Oban.insert()
  end
end
