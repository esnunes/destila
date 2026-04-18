defmodule DestilaWeb.DraftsBoardLive do
  @moduledoc """
  Priority-based kanban board of drafts at /drafts.

  Three columns: High, Medium, Low. Cards are clickable and navigate to
  the draft detail page. Drag-and-drop is handled by the `DraftsBoard`
  JS hook which pushes a `reorder_draft` event.
  """

  use DestilaWeb, :live_view

  require Logger

  alias Destila.Drafts

  @priorities [:high, :medium, :low]

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")

    all_grouped = Drafts.list_all_active()

    {:ok,
     socket
     |> assign(:page_title, "Drafts")
     |> assign(:all_grouped, all_grouped)
     |> assign_projects(all_grouped)
     |> init_streams()}
  end

  def handle_params(params, _uri, socket) do
    project_filter = empty_to_nil(params["project"])
    filtered = filter_by_project(socket.assigns.all_grouped, project_filter)

    {:noreply,
     socket
     |> assign(:project_filter, project_filter)
     |> reset_streams(filtered)
     |> assign_board_flags(socket.assigns.all_grouped, filtered)}
  end

  def handle_info({event, _data}, socket)
      when event in [:draft_created, :draft_updated] do
    all_grouped = Drafts.list_all_active()
    filtered = filter_by_project(all_grouped, socket.assigns.project_filter)

    {:noreply,
     socket
     |> assign(:all_grouped, all_grouped)
     |> assign_projects(all_grouped)
     |> reset_streams(filtered)
     |> assign_board_flags(all_grouped, filtered)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  def handle_event("filter_project", %{"project" => project_id}, socket) do
    {:noreply, push_patch(socket, to: build_path(empty_to_nil(project_id)))}
  end

  def handle_event(
        "reorder_draft",
        %{"draft_id" => draft_id, "priority" => priority_str} = params,
        socket
      ) do
    with {:ok, priority} <- cast_priority(priority_str),
         draft when not is_nil(draft) <- Drafts.get_draft(draft_id) do
      before_id = empty_to_nil(params["before_id"])
      after_id = empty_to_nil(params["after_id"])

      case Drafts.reposition_draft(draft, priority, before_id, after_id) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("reposition_draft failed: #{inspect(reason)} draft_id=#{draft_id}")
      end
    end

    {:noreply, socket}
  end

  defp cast_priority(str) when is_binary(str) do
    case String.to_existing_atom(str) do
      atom when atom in @priorities -> {:ok, atom}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp cast_priority(_), do: :error

  defp empty_to_nil(nil), do: nil
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(id), do: id

  defp filter_by_project(grouped, nil), do: grouped

  defp filter_by_project(grouped, project_id) do
    Map.new(grouped, fn {priority, drafts} ->
      {priority, Enum.filter(drafts, &(&1.project_id == project_id))}
    end)
  end

  defp assign_projects(socket, grouped) do
    projects =
      grouped
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.project)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.name)

    assign(socket, :projects, projects)
  end

  defp init_streams(socket) do
    Enum.reduce(@priorities, socket, fn priority, acc ->
      stream(acc, stream_key(priority), [])
    end)
  end

  defp reset_streams(socket, grouped) do
    Enum.reduce(@priorities, socket, fn priority, acc ->
      stream(acc, stream_key(priority), Map.get(grouped, priority, []), reset: true)
    end)
  end

  defp assign_board_flags(socket, all_grouped, filtered) do
    any_drafts? = Enum.any?(@priorities, fn p -> Map.get(all_grouped, p, []) != [] end)
    any_visible? = Enum.any?(@priorities, fn p -> Map.get(filtered, p, []) != [] end)

    socket
    |> assign(:any_drafts?, any_drafts?)
    |> assign(:any_visible?, any_visible?)
  end

  defp build_path(nil), do: ~p"/drafts"
  defp build_path(project_id), do: ~p"/drafts?project=#{project_id}"

  defp stream_key(:high), do: :drafts_high
  defp stream_key(:medium), do: :drafts_medium
  defp stream_key(:low), do: :drafts_low

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title}>
      <div class="p-6 lg:p-8">
        <div class="flex items-center justify-between mb-4">
          <h1 class="text-2xl font-bold tracking-tight">Drafts</h1>
          <.link navigate={~p"/drafts/new"} class="btn btn-primary btn-sm" id="new-draft-btn">
            <.icon name="hero-plus-micro" class="size-4" /> New Draft
          </.link>
        </div>

        <%= if @any_drafts? do %>
          <div class="flex items-center gap-3 mb-6">
            <form phx-change="filter_project" id="project-filter-form">
              <select
                name="project"
                id="project-filter"
                class="select select-sm select-bordered"
              >
                <option value="">All projects</option>
                <option
                  :for={project <- @projects}
                  value={project.id}
                  selected={@project_filter == project.id}
                >
                  {project.name}
                </option>
              </select>
            </form>
          </div>

          <%= if @any_visible? do %>
            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <.column
                priority={:high}
                label="High"
                stream={@streams.drafts_high}
                accent="text-error"
              />
              <.column
                priority={:medium}
                label="Medium"
                stream={@streams.drafts_medium}
                accent="text-warning"
              />
              <.column
                priority={:low}
                label="Low"
                stream={@streams.drafts_low}
                accent="text-base-content/50"
              />
            </div>
          <% else %>
            <div
              id="drafts-board-no-matches"
              class="flex flex-col items-center justify-center h-32 gap-2 text-base-content/20 text-sm bg-base-200/20 rounded-xl border border-dashed border-base-300/50"
            >
              <.icon name="hero-funnel-micro" class="size-5" /> No drafts match this filter
            </div>
          <% end %>
        <% else %>
          <div class="text-center py-20" id="drafts-board-empty">
            <.icon name="hero-document-text" class="size-12 text-base-content/20 mx-auto mb-3" />
            <p class="text-sm text-base-content/40 mb-4">
              No drafts yet — capture your first idea.
            </p>
            <.link
              navigate={~p"/drafts/new"}
              class="btn btn-primary"
              id="create-first-draft-btn"
            >
              <.icon name="hero-plus-micro" class="size-4" /> Create your first draft
            </.link>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :priority, :atom, required: true
  attr :label, :string, required: true
  attr :stream, :any, required: true
  attr :accent, :string, default: ""

  defp column(assigns) do
    ~H"""
    <div
      id={"column-#{@priority}"}
      phx-hook="DraftsBoard"
      data-priority={@priority}
      class="bg-base-200/40 rounded-lg p-3 flex flex-col gap-2 min-h-[12rem]"
    >
      <header class="flex items-center gap-2 px-1 pb-2 border-b border-base-300/50">
        <span class={["text-sm font-semibold tracking-tight", @accent]}>{@label}</span>
      </header>

      <div id={"drafts-#{@priority}"} phx-update="stream" class="space-y-2 min-h-[2rem]">
        <div :for={{id, draft} <- @stream} id={id} data-draft-id={draft.id}>
          <.link
            navigate={~p"/drafts/#{draft.id}"}
            draggable="true"
            class="block p-3 rounded-lg bg-base-100 shadow-sm hover:shadow-md transition-shadow cursor-pointer"
          >
            <p class="text-sm line-clamp-3 whitespace-pre-wrap">{draft.prompt}</p>
            <div class="flex items-center gap-1 mt-2 text-xs text-base-content/40">
              <.icon name="hero-folder-micro" class="size-3.5" />
              <span class="truncate">{draft.project.name}</span>
              <span :if={draft.project.archived_at} class="ml-1 text-warning">
                (archived)
              </span>
            </div>
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
