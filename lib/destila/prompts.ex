defmodule Destila.Prompts do
  import Ecto.Query

  alias Destila.Repo
  alias Destila.Prompts.Prompt

  def list_prompts do
    Repo.all(from(p in Prompt, order_by: p.position))
  end

  def list_prompts(board) do
    Repo.all(from(p in Prompt, where: p.board == ^board, order_by: p.position))
  end

  def get_prompt(id) do
    Repo.get(Prompt, id)
  end

  def get_prompt!(id) do
    Repo.get!(Prompt, id)
  end

  def create_prompt(attrs) do
    attrs = Map.put_new_lazy(attrs, :position, fn -> System.unique_integer([:positive]) end)

    %Prompt{}
    |> Prompt.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:prompt_created)
  end

  def update_prompt(%Prompt{} = prompt, attrs) do
    prompt
    |> Prompt.changeset(attrs)
    |> Repo.update()
    |> broadcast(:prompt_updated)
  end

  def update_prompt(id, attrs) when is_binary(id) do
    get_prompt!(id) |> update_prompt(attrs)
  end

  def move_card(%Prompt{} = prompt, new_column, new_position) do
    update_prompt(prompt, %{column: new_column, position: new_position})
  end

  def count_by_project(project_id) do
    Repo.aggregate(from(p in Prompt, where: p.project_id == ^project_id), :count)
  end

  def count_by_projects do
    Repo.all(
      from(p in Prompt,
        where: not is_nil(p.project_id),
        group_by: p.project_id,
        select: {p.project_id, count(p.id)}
      )
    )
    |> Map.new()
  end

  @doc """
  Checks if Phase 0 setup is fully complete (both title generation and setup steps)
  and if so, transitions the prompt out of :setup status and triggers Phase 1.

  Called by both TitleGenerationWorker and SetupWorker after they finish.
  Only the last one to complete will actually trigger the transition.
  """
  def maybe_finish_phase0(prompt_id) do
    prompt = get_prompt!(prompt_id)

    if prompt.phase_status != :setup do
      :noop
    else
      phase0_messages =
        Destila.Messages.list_messages(prompt_id)
        |> Enum.filter(&(&1.phase == 0))

      title_done = step_completed?(phase0_messages, "title_generation")

      setup_done =
        if prompt.project_id do
          step_completed?(phase0_messages, "ai_session")
        else
          true
        end

      if title_done && setup_done do
        do_finish_phase0(prompt)
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

  defp do_finish_phase0(prompt) do
    phase = 1
    messages = Destila.Messages.list_messages(prompt.id)

    system_prompt =
      Destila.Workflows.ChoreTaskPhases.system_prompt(phase, prompt)

    context =
      Destila.Workflows.ChoreTaskPhases.build_conversation_context(messages)

    query = system_prompt <> "\n\n" <> context

    update_prompt(prompt.id, %{phase_status: :generating})

    %{"prompt_id" => prompt.id, "phase" => phase, "query" => query}
    |> Destila.Workers.AiQueryWorker.new()
    |> Oban.insert()

    :ok
  end

  defp broadcast({:ok, entity}, event) do
    Phoenix.PubSub.broadcast(Destila.PubSub, "store:updates", {event, entity})
    {:ok, entity}
  end

  defp broadcast({:error, _} = error, _event), do: error
end
