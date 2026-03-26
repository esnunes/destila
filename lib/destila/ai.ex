defmodule Destila.AI do
  @moduledoc """
  Context for AI sessions, messages, and AI-powered utilities.
  """

  import Ecto.Query

  alias Destila.Repo
  alias Destila.AI.{Message, Session}

  # --- AI Sessions ---

  def get_ai_session!(id) do
    Repo.get!(Session, id)
  end

  def get_ai_session_for_workflow(workflow_session_id) do
    Repo.get_by(Session, workflow_session_id: workflow_session_id)
  end

  def get_or_create_ai_session(workflow_session_id, attrs \\ %{}) do
    case get_ai_session_for_workflow(workflow_session_id) do
      nil ->
        %Session{}
        |> Session.changeset(Map.put(attrs, :workflow_session_id, workflow_session_id))
        |> Repo.insert()

      ai_session ->
        {:ok, ai_session}
    end
  end

  def create_ai_session(attrs) do
    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert()
  end

  def update_ai_session(%Session{} = ai_session, attrs) do
    ai_session
    |> Session.changeset(attrs)
    |> Repo.update()
  end

  # --- Messages ---

  def list_messages(ai_session_id) do
    Repo.all(
      from(m in Message,
        where: m.ai_session_id == ^ai_session_id,
        order_by: m.inserted_at
      )
    )
  end

  def list_messages_for_workflow_session(workflow_session_id) do
    Repo.all(
      from(m in Message,
        join: a in assoc(m, :ai_session),
        where: a.workflow_session_id == ^workflow_session_id,
        order_by: m.inserted_at
      )
    )
  end

  def create_message(ai_session_id, attrs) do
    attrs =
      attrs
      |> Map.put(:ai_session_id, ai_session_id)
      |> Map.update(:raw_response, nil, &normalize_keys/1)

    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:message_added)
  end

  @doc """
  Processes a raw message into a display-ready map with derived fields.

  For AI messages (role: :system with raw_response), derives content, message_type,
  input_type, options, and questions from the raw_response.

  For user messages, passes through content and selected.
  """
  def process_message(%Message{role: :user} = msg, _workflow_session) do
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

  def process_message(%Message{role: :system, raw_response: raw} = msg, workflow_session)
      when is_map(raw) do
    {content, message_type} = parse_markers(msg.content, msg.phase, workflow_session)
    {input_type, options, questions} = extract_tool_input(raw)

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

  def process_message(%Message{role: :system} = msg, _workflow_session) do
    %{
      id: msg.id,
      role: :system,
      phase: msg.phase,
      content: msg.content,
      selected: nil,
      inserted_at: msg.inserted_at,
      message_type: nil,
      input_type: :text,
      options: nil,
      questions: []
    }
  end

  def derive_phase_status(text) do
    cond do
      String.contains?(text, "<<SKIP_PHASE>>") -> :conversing
      String.contains?(text, "<<READY_TO_ADVANCE>>") -> :advance_suggested
      true -> :conversing
    end
  end

  def response_text(result) do
    if result.text != nil and result.text != "" do
      result.text
    else
      result.result || ""
    end
  end

  # --- Title Generation ---

  @doc """
  Generates a concise title for a workflow session based on the workflow type
  and the user's initial idea. Uses a one-off ClaudeCode query.

  Returns `{:ok, title}` on success or `{:error, reason}` on failure.
  """
  def generate_title(workflow_type, idea) do
    type_label = workflow_type_label(workflow_type)

    prompt =
      "Generate a concise title (under 60 characters) for a #{type_label}. " <>
        "The user described their idea as: #{idea}\n\n" <>
        "Respond with only the title, no quotes, no punctuation at the end, no explanation."

    opts = [
      model: "haiku",
      system_prompt:
        "You are a title generator. You produce short, descriptive titles. " <>
          "Respond with only the title text, nothing else.",
      max_turns: 1
    ]

    case ClaudeCode.query(prompt, opts) do
      {:ok, result} ->
        title = String.trim(to_string(result))
        if title != "", do: {:ok, title}, else: {:error, :empty_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp workflow_type_label(:prompt_chore_task), do: "chore/task"
  defp workflow_type_label(other), do: to_string(other)

  # --- Private helpers ---

  defp parse_markers(text, phase, workflow_session) do
    cond do
      phase == workflow_session.total_phases ->
        {String.trim(text), :generated_prompt}

      String.contains?(text, "<<SKIP_PHASE>>") ->
        content = String.replace(text, "<<SKIP_PHASE>>", "") |> String.trim()
        content = if content == "", do: "Skipping this phase.", else: content
        {content, :skip_phase}

      String.contains?(text, "<<READY_TO_ADVANCE>>") ->
        content = String.replace(text, "<<READY_TO_ADVANCE>>", "") |> String.trim()
        content = if content == "", do: "Ready to move to the next phase.", else: content
        {content, :phase_advance}

      true ->
        {String.trim(text), nil}
    end
  end

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
      tool["name"] in ["ask_user_question", "mcp__destila__ask_user_question"]
    end)
    |> Enum.flat_map(fn tool ->
      input = tool["input"] || %{}
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

  defdelegate broadcast(result, event), to: Destila.PubSubHelper

  defp normalize_keys(nil), do: nil

  defp normalize_keys(%{__struct__: _} = struct),
    do: struct |> Map.from_struct() |> normalize_keys()

  defp normalize_keys(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), normalize_keys(v)} end)

  defp normalize_keys(list) when is_list(list),
    do: Enum.map(list, &normalize_keys/1)

  defp normalize_keys(other), do: other
end
