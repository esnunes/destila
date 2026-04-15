defmodule DestilaWeb.ArchivedProjectsLive do
  use DestilaWeb, :live_view

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
    end

    projects = Destila.Projects.list_archived_projects()

    {:ok,
     socket
     |> assign(:page_title, "Archived Projects")
     |> assign(:projects, projects)
     |> assign(:session_counts, Destila.Workflows.count_by_projects())}
  end

  def handle_event("unarchive_project", %{"id" => id}, socket) do
    case Destila.Projects.get_project(id) do
      nil ->
        {:noreply, socket}

      project ->
        {:ok, _project} = Destila.Projects.unarchive_project(project)

        {:noreply, put_flash(socket, :info, "Project restored")}
    end
  end

  def handle_info({event, _data}, socket)
      when event in [:project_created, :project_updated, :project_deleted] do
    projects = Destila.Projects.list_archived_projects()

    {:noreply,
     socket
     |> assign(:projects, projects)
     |> assign(:session_counts, Destila.Workflows.count_by_projects())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp linked_session_count(session_counts, project_id) do
    case Map.get(session_counts, project_id, 0) do
      0 -> "No sessions"
      1 -> "1 session"
      n -> "#{n} sessions"
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title}>
      <div class="p-6 lg:p-8">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-2xl font-bold tracking-tight">Archived Projects</h1>
          <.link
            navigate={~p"/projects"}
            class="text-xs text-base-content/40 hover:text-base-content/60 transition-colors flex items-center gap-1"
            id="back-to-projects-link"
          >
            <.icon name="hero-arrow-left-micro" class="size-3.5" /> Back to Projects
          </.link>
        </div>

        <%= if @projects == [] do %>
          <div
            id="archived-empty"
            class="flex items-center justify-center gap-2 h-16 text-base-content/20 text-sm bg-base-200/20 rounded-xl border border-dashed border-base-300/50"
          >
            <.icon name="hero-archive-box-micro" class="size-4" /> No archived projects
          </div>
        <% else %>
          <div id="archived-list" class="space-y-3">
            <div
              :for={project <- @projects}
              id={"archived-project-#{project.id}"}
              class="card bg-base-100 shadow-sm mb-3"
            >
              <div class="card-body p-4 gap-2">
                <div class="flex items-start justify-between">
                  <div class="min-w-0 flex-1">
                    <h4 class="text-sm font-medium leading-tight">{project.name}</h4>
                    <div class="flex flex-col gap-0.5 mt-1">
                      <span
                        :if={project.git_repo_url}
                        class="text-xs text-base-content/40 truncate"
                      >
                        <.icon name="hero-link-micro" class="size-3.5 inline" />
                        {project.git_repo_url}
                      </span>
                      <span :if={project.local_folder} class="text-xs text-base-content/40 truncate">
                        <.icon name="hero-folder-micro" class="size-3.5 inline" />
                        {project.local_folder}
                      </span>
                    </div>
                  </div>

                  <div class="flex items-center gap-1 ml-4 shrink-0">
                    <span class="text-xs text-base-content/40">
                      {linked_session_count(@session_counts, project.id)}
                    </span>

                    <button
                      phx-click="unarchive_project"
                      phx-value-id={project.id}
                      class="btn btn-ghost btn-xs opacity-60 hover:opacity-100 transition-opacity"
                      id={"unarchive-project-#{project.id}"}
                    >
                      <.icon name="hero-arrow-uturn-left-micro" class="size-4" /> Restore
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
