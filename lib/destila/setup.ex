defmodule Destila.Setup do
  @moduledoc """
  Coordinates Phase 0 completion between TitleGenerationWorker and SetupWorker.

  Both workers call `maybe_finish_phase0/1` after completing. This module
  uses an atomic compare-and-swap to ensure exactly one worker triggers
  the Phase 1 transition.
  """

  import Ecto.Query

  alias Destila.{Messages, Repo}
  alias Destila.Prompts.Prompt
  alias Destila.Workflows.ChoreTaskPhases

  @doc """
  Checks if Phase 0 setup is fully complete (both title generation and setup steps)
  and if so, atomically transitions the prompt to :generating and triggers Phase 1.

  Returns :ok if Phase 1 was triggered, :noop otherwise.
  """
  def maybe_finish_phase0(prompt_id) do
    prompt = Destila.Prompts.get_prompt!(prompt_id)

    if prompt.phase_status != :setup do
      :noop
    else
      phase0_messages =
        Messages.list_messages(prompt_id)
        |> Enum.filter(&(&1.phase == 0))

      title_done = step_completed?(phase0_messages, "title_generation")

      setup_done =
        if prompt.project_id do
          step_completed?(phase0_messages, "ai_session")
        else
          true
        end

      if title_done && setup_done do
        # Atomic compare-and-swap: only one worker wins
        {count, _} =
          from(p in Prompt, where: p.id == ^prompt_id and p.phase_status == :setup)
          |> Repo.update_all(set: [phase_status: :generating])

        if count == 1 do
          trigger_phase1(prompt)
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

  defp trigger_phase1(prompt) do
    phase = 1

    # Filter out phase 0 messages — they're setup noise, not conversation context
    messages =
      Messages.list_messages(prompt.id)
      |> Enum.filter(&(&1.phase > 0))

    system_prompt = ChoreTaskPhases.system_prompt(phase, prompt)
    context = ChoreTaskPhases.build_conversation_context(messages)
    query = system_prompt <> "\n\n" <> context

    # Broadcast the prompt update so LiveView picks up the :generating status
    prompt = Destila.Prompts.get_prompt!(prompt.id)
    Phoenix.PubSub.broadcast(Destila.PubSub, "store:updates", {:prompt_updated, prompt})

    %{"prompt_id" => prompt.id, "phase" => phase, "query" => query}
    |> Destila.Workers.AiQueryWorker.new()
    |> Oban.insert()
  end
end
