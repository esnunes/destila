defmodule Destila.Messages do
  import Ecto.Query

  alias Destila.Repo
  alias Destila.Messages.Message

  def list_messages(prompt_id) do
    Repo.all(from(m in Message, where: m.prompt_id == ^prompt_id, order_by: m.inserted_at))
  end

  def create_message(prompt_id, attrs) do
    attrs =
      attrs
      |> Map.put(:prompt_id, prompt_id)

    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:message_added)
  end

  @doc """
  Processes a raw message into a display-ready map with derived fields.

  For AI messages (role: :system with raw_response), derives content, message_type,
  input_type, options, and questions from the raw_response.

  For static workflow messages (role: :system without raw_response), looks up
  input_type/options from the workflow step definition.

  For user messages, passes through content and selected.
  """
  def process(%Message{role: :user} = msg, _prompt) do
    %{
      id: msg.id,
      role: :user,
      phase: msg.phase,
      content: msg.content,
      selected: msg.selected,
      inserted_at: msg.inserted_at,
      message_type: nil,
      input_type: nil,
      options: nil,
      questions: []
    }
  end

  def process(%Message{role: :system, raw_response: raw} = msg, prompt)
      when is_map(raw) do
    {content, message_type} = parse_markers(msg.content, msg.phase, prompt)
    {input_type, options, questions} = extract_tool_input(raw)

    # If AI text is empty/generic but questions exist, use question texts as content
    content =
      if questions != [] and (content == "" or content == "Waiting for your answer.") do
        questions |> Enum.map(& &1.question) |> Enum.join("\n\n")
      else
        content
      end

    %{
      id: msg.id,
      role: :system,
      phase: msg.phase,
      content: content,
      selected: nil,
      inserted_at: msg.inserted_at,
      message_type: message_type,
      input_type: input_type,
      options: options,
      questions: questions
    }
  end

  def process(%Message{role: :system} = msg, prompt) do
    # Static workflow message — look up input_type/options from workflow definition
    {input_type, options} = lookup_static_step(prompt.workflow_type, msg.phase)

    %{
      id: msg.id,
      role: :system,
      phase: msg.phase,
      content: msg.content,
      selected: nil,
      inserted_at: msg.inserted_at,
      message_type: nil,
      input_type: input_type,
      options: options,
      questions: []
    }
  end

  @doc """
  Processes all messages for a prompt into display-ready maps.
  """
  def process_all(messages, prompt) do
    Enum.map(messages, &process(&1, prompt))
  end

  # Strips <<READY_TO_ADVANCE>> and <<SKIP_PHASE>> markers from AI text.
  # Returns {cleaned_content, message_type}.
  defp parse_markers(text, phase, prompt) do
    cond do
      String.contains?(text, "<<SKIP_PHASE>>") ->
        content = String.replace(text, "<<SKIP_PHASE>>", "") |> String.trim()
        content = if content == "", do: "Skipping this phase.", else: content
        {content, :skip_phase}

      String.contains?(text, "<<READY_TO_ADVANCE>>") ->
        content = String.replace(text, "<<READY_TO_ADVANCE>>", "") |> String.trim()
        content = if content == "", do: "Ready to move to the next phase.", else: content
        {content, :phase_advance}

      phase == prompt.steps_total ->
        {String.trim(text), :generated_prompt}

      true ->
        {String.trim(text), nil}
    end
  end

  # Extracts input_type, options, and questions from raw_response mcp_tool_uses.
  defp extract_tool_input(%{"mcp_tool_uses" => tool_uses}) when is_list(tool_uses) do
    questions = extract_questions(tool_uses)

    case questions do
      [] -> {:text, nil, []}
      [q] -> {q.input_type, q.options, questions}
      _ -> {:questions, nil, questions}
    end
  end

  defp extract_tool_input(_), do: {:text, nil, []}

  defp extract_questions(tool_uses) do
    tool_uses
    |> Enum.filter(fn tool ->
      name = tool["name"] || Map.get(tool, :name)
      name in ["ask_user_question", "mcp__destila__ask_user_question"]
    end)
    |> Enum.flat_map(fn tool ->
      input = tool["input"] || Map.get(tool, :input, %{})
      questions = input["questions"] || [input]

      Enum.map(questions, fn q ->
        multi_select = q["multi_select"] == true

        %{
          question: q["question"] || "",
          title: q["title"],
          input_type: if(multi_select, do: :multi_select, else: :single_select),
          options:
            (q["options"] || [])
            |> Enum.map(fn opt ->
              %{label: opt["label"] || "", description: opt["description"]}
            end)
        }
      end)
    end)
  end

  # Looks up input_type and options for a static workflow step.
  defp lookup_static_step(workflow_type, phase) do
    steps = Destila.Workflows.steps(workflow_type)

    case Enum.find(steps, fn s -> s.step == phase end) do
      nil -> {:text, nil}
      step -> {step.input_type, step.options}
    end
  end

  defp broadcast({:ok, entity}, event) do
    Phoenix.PubSub.broadcast(Destila.PubSub, "store:updates", {event, entity})
    {:ok, entity}
  end

  defp broadcast({:error, _} = error, _event), do: error
end
