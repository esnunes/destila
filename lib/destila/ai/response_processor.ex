defmodule Destila.AI.ResponseProcessor do
  @moduledoc """
  Transforms raw AI messages and responses into UI-ready maps.

  Handles message processing, session action extraction, tool input parsing,
  and question extraction from MCP tool uses.
  """

  alias Destila.AI.Message

  @session_tool_names ["session", "mcp__destila__session"]

  # --- Public API ---

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
      questions: [],
      exports: []
    }
  end

  def process_message(%Message{role: :system, raw_response: raw} = msg, workflow_session)
      when is_map(raw) do
    {override_content, message_type} = derive_message_type(raw, msg.phase, workflow_session)
    {input_type, options, questions} = extract_tool_input(raw)
    exports = extract_export_actions(raw)

    content = override_content || String.trim(msg.content)

    # If questions were extracted and content is empty/placeholder, derive from questions
    content =
      if questions != [] and (content == "" or content == "Waiting for your answer.") do
        questions |> Enum.map(& &1.question) |> Enum.join("\n\n")
      else
        content
      end

    # When session tool is active, suppress question UI
    {input_type, options, questions} =
      if message_type == :phase_advance do
        {:text, nil, []}
      else
        {input_type, options, questions}
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
      questions: questions,
      exports: exports
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
      questions: [],
      exports: []
    }
  end

  @doc """
  Extracts the first session tool call from an AI result or raw_response map.

  Handles both atom-keyed maps (from the streaming collector in the worker) and
  string-keyed maps (from DB JSON in `process_message`). Returns a map with
  `:action` and `:message` keys, or `nil` if no session tool was called.
  """
  def extract_session_action(%{mcp_tool_uses: tool_uses}) when is_list(tool_uses) do
    do_extract_session_action(tool_uses)
  end

  def extract_session_action(%{"mcp_tool_uses" => tool_uses}) when is_list(tool_uses) do
    do_extract_session_action(tool_uses)
  end

  def extract_session_action(_), do: nil

  @doc """
  Extracts all export actions from an AI result's MCP tool uses.

  Returns a list of `%{key: key, value: value, type: type}` maps. Type is `nil` when omitted.
  """
  def extract_export_actions(%{mcp_tool_uses: tool_uses}) when is_list(tool_uses) do
    do_extract_export_actions(tool_uses)
  end

  def extract_export_actions(%{"mcp_tool_uses" => tool_uses}) when is_list(tool_uses) do
    do_extract_export_actions(tool_uses)
  end

  def extract_export_actions(_), do: []

  def response_text(result) do
    if result.text != nil and result.text != "" do
      result.text
    else
      result.result || ""
    end
  end

  # --- Private helpers ---

  defp do_extract_session_action(tool_uses) do
    Enum.find_value(tool_uses, fn tool ->
      name = access(tool, :name)

      if name in @session_tool_names do
        input = access(tool, :input) || %{}
        action = access(input, :action)

        # Skip export actions — they're handled by extract_export_actions/1
        if action != "export" do
          %{action: action, message: access(input, :message)}
        end
      end
    end)
  end

  defp do_extract_export_actions(tool_uses) do
    Enum.flat_map(tool_uses, fn tool ->
      name = access(tool, :name)

      if name in @session_tool_names do
        input = access(tool, :input) || %{}

        if access(input, :action) == "export" do
          [%{key: access(input, :key), value: access(input, :value), type: access(input, :type)}]
        else
          []
        end
      else
        []
      end
    end)
  end

  # Access a key from a struct (atom key) or map (string key).
  defp access(map, key) when is_struct(map), do: Map.get(map, key)

  defp access(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil -> Map.get(map, to_string(key))
      val -> val
    end
  end

  defp derive_message_type(raw, _phase, _workflow_session) do
    cond do
      session = extract_session_action(raw) ->
        case session.action do
          "suggest_phase_complete" ->
            {session.message || "Ready to move to the next phase.", :phase_advance}

          "phase_complete" ->
            {session.message || "Moving to the next phase.", :phase_advance}

          _ ->
            {nil, nil}
        end

      true ->
        {nil, nil}
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
      questions = parse_questions(input["questions"], input)

      Enum.map(questions, fn q ->
        multi_select = q["multi_select"] == true

        %{
          question: q["question"] || q["text"] || "",
          title: q["title"],
          input_type: if(multi_select, do: :multi_select, else: :single_select),
          options:
            (q["options"] || [])
            |> Enum.map(fn
              opt when is_binary(opt) -> %{label: opt, description: nil}
              opt -> %{label: opt["label"] || "", description: opt["description"]}
            end)
        }
      end)
    end)
  end

  defp parse_questions(raw, input) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, list} when is_list(list) -> list
      _ -> [input]
    end
  end

  defp parse_questions(list, _input) when is_list(list), do: list
  defp parse_questions(_, input), do: [input]
end
