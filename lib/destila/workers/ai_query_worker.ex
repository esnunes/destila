defmodule Destila.Workers.AiQueryWorker do
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Destila.{Messages, Prompts}
  alias Destila.Workflows.ChoreTaskPhases

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"prompt_id" => prompt_id, "phase" => phase, "query" => query}}) do
    case Destila.AI.Session.for_prompt(prompt_id) do
      {:ok, session} ->
        handle_query(prompt_id, phase, session, query)

      {:error, reason} ->
        Messages.create_message(prompt_id, %{
          role: :system,
          content: "Something went wrong. Please try sending your message again.",
          phase: phase
        })

        Prompts.update_prompt(prompt_id, %{phase_status: :conversing})
        {:error, reason}
    end
  end

  defp handle_query(prompt_id, phase, session, query) do
    case Destila.AI.Session.query(session, query) do
      {:ok, result} ->
        response_text = Messages.response_text(result)
        new_phase_status = Messages.derive_phase_status(response_text)

        Messages.create_message(prompt_id, %{
          role: :system,
          content: response_text,
          raw_response: result,
          phase: phase
        })

        if String.contains?(response_text, "<<SKIP_PHASE>>") do
          handle_skip_phase(prompt_id, phase)
        else
          update_attrs = %{phase_status: new_phase_status}

          update_attrs =
            if result[:session_id],
              do: Map.put(update_attrs, :session_id, result[:session_id]),
              else: update_attrs

          Prompts.update_prompt(prompt_id, update_attrs)
        end

        :ok

      {:error, _} ->
        Messages.create_message(prompt_id, %{
          role: :system,
          content: "Something went wrong. Please try sending your message again.",
          phase: phase
        })

        Prompts.update_prompt(prompt_id, %{phase_status: :conversing})
        :ok
    end
  end

  defp handle_skip_phase(prompt_id, current_phase) do
    next_phase = current_phase + 1

    Prompts.update_prompt(prompt_id, %{
      steps_completed: next_phase,
      phase_status: :generating
    })

    prompt = Prompts.get_prompt!(prompt_id)
    phase_prompt = ChoreTaskPhases.system_prompt(next_phase, prompt)

    %{"prompt_id" => prompt_id, "phase" => next_phase, "query" => phase_prompt}
    |> __MODULE__.new()
    |> Oban.insert()
  end
end
