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

  def list_ai_sessions_for_workflow(workflow_session_id) do
    Repo.all(
      from(s in Session,
        where: s.workflow_session_id == ^workflow_session_id,
        order_by: [asc: s.inserted_at]
      )
    )
  end

  def get_ai_session(id) do
    Repo.get(Session, id)
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

  def list_messages_for_ai_session(ai_session_id) do
    Repo.all(
      from(m in Message,
        where: m.ai_session_id == ^ai_session_id,
        order_by: m.inserted_at
      )
    )
  end

  @doc """
  Sums per-turn usage and cost from the stored `raw_response` maps of all
  system (assistant) messages for an AI session.

  Returns a map with integer token counts, float `total_cost_usd`, float
  `duration_ms`, and a `turns` count (number of turns that contributed usage).
  Returns zeros when no usage has been recorded yet.
  """
  def aggregate_usage_for_ai_session(ai_session_id) do
    ai_session_id
    |> list_messages_for_ai_session()
    |> Enum.reduce(empty_usage_totals(), &add_message_usage/2)
  end

  defp empty_usage_totals do
    %{
      input_tokens: 0,
      output_tokens: 0,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0,
      total_cost_usd: 0.0,
      duration_ms: 0.0,
      turns: 0
    }
  end

  defp add_message_usage(%Message{raw_response: raw}, acc) when is_map(raw) do
    usage = Map.get(raw, "usage") || %{}

    %{
      input_tokens: acc.input_tokens + read_int(usage, "input_tokens"),
      output_tokens: acc.output_tokens + read_int(usage, "output_tokens"),
      cache_read_input_tokens:
        acc.cache_read_input_tokens + read_int(usage, "cache_read_input_tokens"),
      cache_creation_input_tokens:
        acc.cache_creation_input_tokens + read_int(usage, "cache_creation_input_tokens"),
      total_cost_usd: acc.total_cost_usd + read_float(raw, "total_cost_usd"),
      duration_ms: acc.duration_ms + read_float(raw, "duration_ms"),
      turns: acc.turns + if(usage == %{}, do: 0, else: 1)
    }
  end

  defp add_message_usage(_msg, acc), do: acc

  defp read_int(map, key) do
    case Map.get(map, key) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp read_float(map, key) do
    case Map.get(map, key) do
      n when is_float(n) -> n
      n when is_integer(n) -> n * 1.0
      _ -> 0.0
    end
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
