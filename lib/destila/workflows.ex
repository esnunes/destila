defmodule Destila.Workflows do
  @moduledoc """
  Thin dispatcher that routes workflow operations to the appropriate
  workflow module based on `workflow_type`.
  """

  import Ecto.Query

  alias Destila.Repo
  alias Destila.Workflows.{Session, SessionMetadata}

  @workflow_modules %{
    brainstorm_idea: Destila.Workflows.BrainstormIdeaWorkflow,
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

  def creation_config(workflow_type), do: workflow_module(workflow_type).creation_config()

  def list_source_sessions(workflow_type) do
    {source_key, _label, _dest_key} = creation_config(workflow_type)

    if source_key do
      list_sessions_with_exported_metadata(source_key)
    else
      []
    end
  end

  def creation_label(workflow_type) do
    {_source_key, label, _dest_key} = creation_config(workflow_type)
    label
  end

  def phases(workflow_type), do: workflow_module(workflow_type).phases()
  def total_phases(workflow_type), do: workflow_module(workflow_type).total_phases()
  def phase_name(workflow_type, phase), do: workflow_module(workflow_type).phase_name(phase)
  def phase_columns(workflow_type), do: workflow_module(workflow_type).phase_columns()
  def default_title(workflow_type), do: workflow_module(workflow_type).default_title()
  def completion_message(workflow_type), do: workflow_module(workflow_type).completion_message()

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

  def create_workflow_session(params) do
    %{
      workflow_type: workflow_type,
      input_text: input_text
    } = params

    selected_session_id = Map.get(params, :selected_session_id)
    project_id = Map.get(params, :project_id)
    {_source_key, _label, dest_key} = creation_config(workflow_type)

    title =
      if selected_session_id do
        source = get_workflow_session(selected_session_id)
        if source, do: source.title, else: default_title(workflow_type)
      else
        default_title(workflow_type)
      end

    title_generating = is_nil(selected_session_id)

    session_attrs =
      %{
        title: title,
        workflow_type: workflow_type,
        current_phase: 1,
        total_phases: total_phases(workflow_type),
        title_generating: title_generating
      }
      |> maybe_put(:project_id, project_id)

    with {:ok, ws} <- insert_workflow_session(session_attrs) do
      upsert_metadata(ws.id, "creation", dest_key, %{"text" => input_text})

      if selected_session_id do
        upsert_metadata(ws.id, "creation", "source_session", %{"id" => selected_session_id})
      end

      if title_generating do
        %{"workflow_session_id" => ws.id, "idea" => input_text}
        |> Destila.Workers.TitleGenerationWorker.new()
        |> Oban.insert()
      end

      prepare_workflow_session(ws)

      {:ok, ws}
    end
  end

  @doc false
  def insert_workflow_session(attrs) do
    attrs = Map.put_new_lazy(attrs, :position, fn -> System.unique_integer([:positive]) end)

    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:workflow_session_created)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  def prepare_workflow_session(%Session{} = ws) do
    case Destila.Workflows.Setup.start(ws) do
      :setup_complete ->
        Destila.Executions.Engine.start_session(ws)

      :processing ->
        :ok
    end
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

  def classify(%Session{} = ws) do
    cond do
      Session.done?(ws) -> :done
      Session.phase_status(ws) in [:awaiting_input, :awaiting_confirmation] -> :waiting_for_user
      true -> :processing
    end
  end

  @doc """
  Lists completed, non-archived sessions that have an exported metadata entry
  with the given key. Returns `{session, text}` tuples, ordered by most recent.
  """
  def list_sessions_with_exported_metadata(metadata_key) do
    from(ws in Session,
      join: m in SessionMetadata,
      on: m.workflow_session_id == ws.id and m.key == ^metadata_key and m.exported == true,
      where: not is_nil(ws.done_at) and is_nil(ws.archived_at),
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
    # If PE was processing when archived, transition to awaiting_input
    # since the ClaudeSession was killed during archival
    case Destila.Executions.get_current_phase_execution(ws.id) do
      %{status: :processing} = pe -> Destila.Executions.await_input(pe)
      _ -> :ok
    end

    ws
    |> Session.changeset(%{archived_at: nil})
    |> Repo.update()
    |> broadcast(:workflow_session_updated)
  end

  # --- Metadata ---

  def upsert_metadata(workflow_session_id, phase_name, key, value, opts \\ []) do
    exported = Keyword.get(opts, :exported, false)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %SessionMetadata{}
    |> SessionMetadata.changeset(%{
      workflow_session_id: workflow_session_id,
      phase_name: phase_name,
      key: key,
      value: value,
      exported: exported
    })
    |> Repo.insert(
      on_conflict: {:replace, [:value, :exported, :updated_at]},
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
    workflow_session_id
    |> get_all_metadata()
    |> Enum.reduce(%{}, fn m, acc -> Map.put(acc, m.key, m.value) end)
  end

  def get_exported_metadata(workflow_session_id) do
    workflow_session_id
    |> get_all_metadata()
    |> Enum.filter(& &1.exported)
  end

  def get_all_metadata(workflow_session_id) do
    from(m in SessionMetadata,
      where: m.workflow_session_id == ^workflow_session_id,
      order_by: [m.phase_name, m.key]
    )
    |> Repo.all()
  end

  defdelegate broadcast(result, event), to: Destila.PubSubHelper
end
