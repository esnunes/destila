defmodule Destila.AI do
  @moduledoc """
  Context for AI sessions, messages, and AI-powered utilities.
  """

  import Ecto.Query
  require Logger

  alias Destila.Repo
  alias Destila.AI.{Message, Session}

  # --- AI Sessions ---

  def get_ai_session_for_workflow(workflow_session_id) do
    Repo.one(
      from(s in Session,
        where: s.workflow_session_id == ^workflow_session_id,
        order_by: [desc: s.inserted_at],
        limit: 1
      )
    )
  end

  def get_ai_session_for_workflow!(workflow_session_id) do
    Repo.one!(
      from(s in Session,
        where: s.workflow_session_id == ^workflow_session_id,
        order_by: [desc: s.inserted_at],
        limit: 1
      )
    )
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

  def list_messages_for_workflow_session(workflow_session_id) do
    Repo.all(
      from(m in Message,
        where: m.workflow_session_id == ^workflow_session_id,
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

    try do
      case ClaudeCode.query(prompt, opts) do
        {:ok, result} ->
          title = String.trim(to_string(result))
          if title != "", do: {:ok, title}, else: {:error, :empty_response}

        {:error, reason} ->
          Logger.warning("Title generation failed: #{inspect(reason)}")
          {:error, reason}
      end
    catch
      kind, reason ->
        Logger.warning(
          "Title generation crashed: #{inspect(kind)} #{inspect(reason)}\n" <>
            Exception.format_stacktrace(__STACKTRACE__)
        )

        {:error, {kind, reason}}
    end
  end

  defp workflow_type_label(:brainstorm_idea), do: "brainstorm idea"
  defp workflow_type_label(:implement_general_prompt), do: "prompt implementation"
  defp workflow_type_label(other), do: to_string(other)

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
