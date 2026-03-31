defmodule Destila.Workflows do
  @moduledoc """
  Thin dispatcher that routes workflow operations to the appropriate
  workflow module based on `workflow_type`.
  """

  import Ecto.Query

  alias Destila.Repo
  alias Destila.Workflows.{Session, SessionMetadata}

  @workflow_modules %{
    prompt_chore_task: Destila.Workflows.PromptChoreTaskWorkflow,
    implement_general_prompt: Destila.Workflows.ImplementGeneralPromptWorkflow
  }

  def workflow_module(workflow_type) do
    Map.fetch!(@workflow_modules, workflow_type)
  end

  def workflow_types, do: Map.keys(@workflow_modules)

  def workflow_type_metadata do
    Enum.map(@workflow_modules, fn {type, mod} ->
      %{
        type: type,
        label: mod.label(),
        description: mod.description(),
        icon: mod.icon(),
        icon_class: mod.icon_class()
      }
    end)
  end

  def phases(workflow_type), do: workflow_module(workflow_type).phases()
  def total_phases(workflow_type), do: workflow_module(workflow_type).total_phases()
  def phase_name(workflow_type, phase), do: workflow_module(workflow_type).phase_name(phase)
  def phase_columns(workflow_type), do: workflow_module(workflow_type).phase_columns()
  def default_title(workflow_type), do: workflow_module(workflow_type).default_title()
  def completion_message(workflow_type), do: workflow_module(workflow_type).completion_message()

  def session_strategy(workflow_type, phase) do
    workflow_module(workflow_type).session_strategy(phase) |> normalize_strategy()
  end

  def phase_start_action(workflow_session) do
    workflow_module(workflow_session.workflow_type).phase_start_action(
      workflow_session,
      workflow_session.current_phase
    )
  end

  def phase_update_action(workflow_session, params) do
    workflow_module(workflow_session.workflow_type).phase_update_action(
      workflow_session,
      workflow_session.current_phase,
      params
    )
  end

  defp normalize_strategy(:resume), do: {:resume, []}
  defp normalize_strategy(:new), do: {:new, []}
  defp normalize_strategy({action, opts}) when action in [:resume, :new], do: {action, opts}

  # --- Session CRUD ---

  def list_workflow_sessions do
    from(ws in Session,
      where: is_nil(ws.archived_at),
      order_by: ws.position
    )
    |> preload(:project)
    |> Repo.all()
  end

  def list_archived_workflow_sessions do
    from(ws in Session,
      where: not is_nil(ws.archived_at),
      order_by: [desc: ws.archived_at]
    )
    |> preload(:project)
    |> Repo.all()
  end

  def get_workflow_session(id) do
    Repo.get(Session, id)
  end

  def get_workflow_session!(id) do
    Repo.get!(Session, id)
  end

  def create_workflow_session(attrs) do
    attrs = Map.put_new_lazy(attrs, :position, fn -> System.unique_integer([:positive]) end)

    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:workflow_session_created)
  end

  def update_workflow_session(%Session{} = workflow_session, attrs) do
    workflow_session
    |> Session.changeset(attrs)
    |> Repo.update()
    |> broadcast(:workflow_session_updated)
  end

  def update_workflow_session(id, attrs) when is_binary(id) do
    get_workflow_session!(id) |> update_workflow_session(attrs)
  end

  def classify(%Session{} = workflow_session) do
    cond do
      Session.done?(workflow_session) ->
        :done

      workflow_session.phase_status == :setup ->
        :setup

      true ->
        # Check phase execution first, fall back to phase_status
        case Destila.Executions.get_current_phase_execution(workflow_session.id) do
          %{status: status} when status in ["awaiting_input", "awaiting_confirmation"] ->
            :waiting_for_user

          %{status: "processing"} ->
            :ai_processing

          _ ->
            # Fallback to legacy phase_status
            case workflow_session.phase_status do
              status when status in [:awaiting_input, :advance_suggested] -> :waiting_for_user
              :processing -> :ai_processing
              _ -> :in_progress
            end
        end
    end
  end

  @doc """
  Lists completed workflow sessions that have a `prompt_generated` metadata entry.
  Returns `{session, prompt_text}` tuples, ordered by most recently done.
  """
  def list_sessions_with_generated_prompts do
    from(ws in Session,
      join: m in SessionMetadata,
      on: m.workflow_session_id == ws.id and m.key == "prompt_generated",
      where: not is_nil(ws.done_at),
      preload: [:project],
      order_by: [desc: ws.done_at],
      select: {ws, m.value}
    )
    |> Repo.all()
    |> Enum.map(fn {ws, value} -> {ws, value["text"]} end)
    |> Enum.reject(fn {_ws, text} -> is_nil(text) || text == "" end)
  end

  def count_by_project(project_id) do
    Repo.aggregate(
      from(ws in Session, where: ws.project_id == ^project_id),
      :count
    )
  end

  def count_by_projects do
    Repo.all(
      from(ws in Session,
        where: not is_nil(ws.project_id),
        group_by: ws.project_id,
        select: {ws.project_id, count(ws.id)}
      )
    )
    |> Map.new()
  end

  def archive_workflow_session(%Session{} = ws) do
    Destila.AI.ClaudeSession.stop_for_workflow_session(ws.id)

    ws
    |> Session.changeset(%{archived_at: DateTime.utc_now()})
    |> Repo.update()
    |> broadcast(:workflow_session_updated)
  end

  def unarchive_workflow_session(%Session{} = ws) do
    attrs =
      if ws.phase_status == :processing,
        do: %{archived_at: nil, phase_status: :awaiting_input},
        else: %{archived_at: nil}

    ws
    |> Session.changeset(attrs)
    |> Repo.update()
    |> broadcast(:workflow_session_updated)
  end

  # --- Metadata ---

  def upsert_metadata(workflow_session_id, phase_name, key, value) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %SessionMetadata{}
    |> SessionMetadata.changeset(%{
      workflow_session_id: workflow_session_id,
      phase_name: phase_name,
      key: key,
      value: value
    })
    |> Repo.insert(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:workflow_session_id, :phase_name, :key],
      set: [updated_at: now]
    )
    |> case do
      {:ok, metadata} ->
        Destila.PubSubHelper.broadcast_event(:metadata_updated, workflow_session_id)
        {:ok, metadata}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def get_metadata(workflow_session_id) do
    from(m in SessionMetadata,
      where: m.workflow_session_id == ^workflow_session_id,
      order_by: m.phase_name
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn m, acc -> Map.put(acc, m.key, m.value) end)
  end

  defdelegate broadcast(result, event), to: Destila.PubSubHelper
end
