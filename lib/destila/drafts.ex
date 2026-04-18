defmodule Destila.Drafts do
  @moduledoc """
  Drafts context. Drafts are lightweight prompt + project + priority triples
  that live on a kanban board before being promoted to a workflow session.
  """

  import Ecto.Query

  alias Destila.Repo
  alias Destila.Drafts.Draft
  alias Destila.Projects.Project

  @priorities [:low, :medium, :high]

  @doc "Returns the list of supported priorities."
  def priorities, do: @priorities

  def list_drafts_by_priority(priority) do
    Repo.all(
      from(d in Draft,
        where: d.priority == ^priority and is_nil(d.archived_at),
        order_by: [asc: d.position, asc: d.inserted_at],
        preload: :project
      )
    )
  end

  @doc """
  Returns a map of `:low | :medium | :high` -> list of active drafts, each
  ordered ascending by position then inserted_at.
  """
  def list_all_active do
    drafts =
      Repo.all(
        from(d in Draft,
          where: is_nil(d.archived_at),
          order_by: [asc: d.position, asc: d.inserted_at],
          preload: :project
        )
      )

    grouped = Enum.group_by(drafts, & &1.priority)
    Map.new(@priorities, fn p -> {p, Map.get(grouped, p, [])} end)
  end

  def get_draft(id) do
    Repo.one(
      from(d in Draft,
        where: d.id == ^id and is_nil(d.archived_at),
        preload: :project
      )
    )
  end

  def get_draft!(id) do
    Repo.one!(
      from(d in Draft,
        where: d.id == ^id and is_nil(d.archived_at),
        preload: :project
      )
    )
  end

  def create_draft(attrs) do
    attrs = normalize_attrs(attrs)

    with :ok <- validate_project(attrs[:project_id]),
         :ok <- validate_priority(attrs[:priority]) do
      attrs = Map.put(attrs, :position, next_position(attrs[:priority]))

      %Draft{}
      |> Draft.changeset(attrs)
      |> Repo.insert()
      |> preload_result()
      |> broadcast(:draft_created)
    else
      {:error, {:project, reason}} ->
        {:error, project_error_changeset(attrs, reason)}

      {:error, :invalid_priority} ->
        {:error,
         %Draft{}
         |> Draft.changeset(attrs)
         |> Map.put(:action, :insert)}
    end
  end

  defp validate_priority(priority) when priority in @priorities, do: :ok
  defp validate_priority(_), do: {:error, :invalid_priority}

  def update_draft(%Draft{} = draft, attrs) do
    attrs = normalize_attrs(attrs)

    with :ok <- maybe_validate_project(attrs) do
      attrs =
        if attrs[:priority] && attrs[:priority] != draft.priority do
          Map.put(attrs, :position, next_position(attrs[:priority]))
        else
          attrs
        end

      draft
      |> Draft.changeset(attrs)
      |> Repo.update()
      |> preload_result()
      |> broadcast(:draft_updated)
    else
      {:error, {:project, reason}} ->
        {:error,
         draft
         |> Draft.changeset(attrs)
         |> Ecto.Changeset.add_error(:project_id, project_error_message(reason))
         |> Map.put(:action, :update)}
    end
  end

  defp maybe_validate_project(attrs) do
    if Map.has_key?(attrs, :project_id) do
      validate_project(attrs[:project_id])
    else
      :ok
    end
  end

  def archive_draft(%Draft{} = draft) do
    draft
    |> Draft.changeset(%{archived_at: DateTime.utc_now()})
    |> Repo.update()
    |> preload_result()
    |> broadcast(:draft_updated)
  end

  @doc """
  Repositions a draft within a priority column or moves it to a new one.
  `before_id` is the neighbor immediately above the drop point; `after_id`
  is the neighbor immediately below. Either or both may be nil.
  """
  def reposition_draft(%Draft{} = draft, target_priority, before_id, after_id)
      when target_priority in @priorities do
    before_draft = before_id && Repo.get(Draft, before_id)
    after_draft = after_id && Repo.get(Draft, after_id)

    position = compute_position(target_priority, before_draft, after_draft)

    draft
    |> Draft.changeset(%{priority: target_priority, position: position})
    |> Repo.update()
    |> preload_result()
    |> broadcast(:draft_updated)
  end

  defp compute_position(priority, nil, nil) do
    next_position(priority)
  end

  defp compute_position(_priority, nil, %Draft{position: pos}), do: pos - 1.0
  defp compute_position(_priority, %Draft{position: pos}, nil), do: pos + 1.0

  defp compute_position(_priority, %Draft{position: before_pos}, %Draft{position: after_pos}) do
    (before_pos + after_pos) / 2
  end

  defp next_position(priority) do
    max =
      Repo.one(
        from(d in Draft,
          where: d.priority == ^priority and is_nil(d.archived_at),
          select: max(d.position)
        )
      )

    case max do
      nil -> 1.0
      value -> value + 1.0
    end
  end

  defp validate_project(nil), do: {:error, {:project, :missing}}

  defp validate_project(project_id) do
    case Repo.get(Project, project_id) do
      nil -> {:error, {:project, :not_found}}
      %Project{archived_at: nil} -> :ok
      %Project{} -> {:error, {:project, :archived}}
    end
  end

  defp project_error_changeset(attrs, reason) do
    %Draft{}
    |> Draft.changeset(attrs)
    |> Ecto.Changeset.add_error(:project_id, project_error_message(reason))
    |> Map.put(:action, :insert)
  end

  defp project_error_message(:missing), do: "can't be blank"
  defp project_error_message(:not_found), do: "does not exist"
  defp project_error_message(:archived), do: "is archived"

  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} ->
      key = if is_binary(k), do: String.to_existing_atom(k), else: k
      {key, normalize_value(key, v)}
    end)
  end

  defp normalize_value(:priority, value) when is_binary(value) and value != "" do
    String.to_existing_atom(value)
  end

  defp normalize_value(:priority, ""), do: nil
  defp normalize_value(_key, value), do: value

  defp preload_result({:ok, draft}), do: {:ok, Repo.preload(draft, :project)}
  defp preload_result({:error, _} = error), do: error

  defdelegate broadcast(result, event), to: Destila.PubSubHelper
end
