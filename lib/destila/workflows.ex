defmodule Destila.Workflows do
  @moduledoc """
  Thin dispatcher that routes workflow operations to the appropriate
  workflow module based on `workflow_type`.
  """

  import Ecto.Query

  alias Destila.Repo
  alias Destila.Workflows.{Session, SessionMetadata}

  @workflow_modules %{
    prompt_chore_task: Destila.Workflows.PromptChoreTaskWorkflow
  }

  def workflow_module(workflow_type) when is_atom(workflow_type) do
    Map.fetch!(@workflow_modules, workflow_type)
  end

  def workflow_module(workflow_type) when is_binary(workflow_type) do
    {_type, mod} =
      Enum.find(@workflow_modules, fn {type, _mod} ->
        Atom.to_string(type) == workflow_type
      end) || raise ArgumentError, "unknown workflow type: #{workflow_type}"

    mod
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
    module = workflow_module(workflow_type)

    strategy =
      if function_exported?(module, :session_strategy, 1) do
        module.session_strategy(phase)
      else
        :resume
      end

    normalize_strategy(strategy)
  end

  defp normalize_strategy(:resume), do: {:resume, []}
  defp normalize_strategy(:new), do: {:new, []}
  defp normalize_strategy({action, opts}) when action in [:resume, :new], do: {action, opts}

  # --- High-level workflow operations ---

  @doc """
  Advances the workflow session to the next phase.

  Checks the session strategy for the next phase and stops the ClaudeSession
  if the strategy is `:new`. Accepts an optional `phase_status` (defaults to `nil`).

  Returns `{:ok, updated_session}` or `{:error, :at_boundary}` if already at the last phase.
  """
  def advance_phase(%Session{} = ws, opts \\ []) do
    next_phase = ws.current_phase + 1

    if next_phase > ws.total_phases do
      {:error, :at_boundary}
    else
      {action, _} = session_strategy(ws.workflow_type, next_phase)

      if action == :new do
        Destila.AI.ClaudeSession.stop_for_workflow_session(ws.id)
      end

      phase_status = Keyword.get(opts, :phase_status)
      update_workflow_session(ws, %{current_phase: next_phase, phase_status: phase_status})
    end
  end

  @doc """
  Marks a workflow session as done.

  Creates a completion message in the AI session (if one exists) and sets `done_at`.

  Returns `{:ok, updated_session}`.
  """
  def mark_done(%Session{} = ws) do
    ai_session = Destila.AI.get_ai_session_for_workflow(ws.id)

    if ai_session do
      Destila.AI.create_message(ai_session.id, %{
        role: :system,
        content: completion_message(ws.workflow_type),
        phase: ws.current_phase
      })
    end

    update_workflow_session(ws, %{done_at: DateTime.utc_now(), phase_status: nil})
  end

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
      Session.done?(workflow_session) -> :done
      workflow_session.phase_status == :setup -> :setup
      workflow_session.phase_status in [:conversing, :advance_suggested] -> :waiting_for_user
      workflow_session.phase_status == :generating -> :ai_processing
      true -> :in_progress
    end
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
      if ws.phase_status == :generating,
        do: %{archived_at: nil, phase_status: :conversing},
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
