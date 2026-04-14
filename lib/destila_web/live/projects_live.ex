defmodule DestilaWeb.ProjectsLive do
  use DestilaWeb, :live_view

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
    end

    projects = Destila.Projects.list_projects()

    {:ok,
     socket
     |> assign(:page_title, "Projects")
     |> stream(:projects, projects)
     |> assign(:projects_empty?, projects == [])
     |> assign(:session_counts, Destila.Workflows.count_by_projects())
     |> assign(:creating, false)
     |> assign(:editing_project_id, nil)
     |> assign(:delete_confirming_id, nil)}
  end

  def handle_event("new_project", _params, socket) do
    {:noreply,
     socket
     |> assign(:creating, true)
     |> assign(:editing_project_id, nil)}
  end

  def handle_event("cancel", _params, socket) do
    socket =
      socket
      |> maybe_restream_project(socket.assigns.editing_project_id)
      |> maybe_restream_project(socket.assigns.delete_confirming_id)
      |> assign(:creating, false)
      |> assign(:editing_project_id, nil)
      |> assign(:delete_confirming_id, nil)

    {:noreply, socket}
  end

  def handle_event("edit_project", %{"id" => id}, socket) do
    project = Destila.Projects.get_project(id)

    if project do
      {:noreply,
       socket
       |> stream_insert(:projects, project)
       |> assign(:editing_project_id, id)
       |> assign(:creating, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    project = Destila.Projects.get_project(id)

    socket =
      if project do
        stream_insert(socket, :projects, project)
      else
        socket
      end

    {:noreply, assign(socket, :delete_confirming_id, id)}
  end

  def handle_event("delete_project", %{"id" => id}, socket) do
    case Destila.Projects.get_project(id) do
      nil ->
        {:noreply, assign(socket, :delete_confirming_id, nil)}

      project ->
        case Destila.Projects.delete_project(project) do
          :ok ->
            {:noreply, assign(socket, :delete_confirming_id, nil)}

          {:error, :has_linked_sessions} ->
            {:noreply,
             socket
             |> maybe_restream_project(id)
             |> assign(:delete_confirming_id, nil)
             |> put_flash(:error, "Cannot delete this project while it is linked to sessions")}
        end
    end
  end

  # Project form callback

  def handle_info({:project_saved, _project}, socket) do
    projects = Destila.Projects.list_projects()

    {:noreply,
     socket
     |> assign(:creating, false)
     |> assign(:editing_project_id, nil)
     |> stream(:projects, projects, reset: true)
     |> assign(:projects_empty?, projects == [])
     |> assign(:session_counts, Destila.Workflows.count_by_projects())}
  end

  # PubSub handlers

  def handle_info({:project_created, _project}, socket) do
    projects = Destila.Projects.list_projects()

    {:noreply,
     socket
     |> stream(:projects, projects, reset: true)
     |> assign(:projects_empty?, projects == [])
     |> assign(:session_counts, Destila.Workflows.count_by_projects())}
  end

  def handle_info({:project_updated, _project}, socket) do
    projects = Destila.Projects.list_projects()

    {:noreply,
     socket
     |> stream(:projects, projects, reset: true)
     |> assign(:projects_empty?, projects == [])
     |> assign(:session_counts, Destila.Workflows.count_by_projects())}
  end

  def handle_info({:project_deleted, _project}, socket) do
    projects = Destila.Projects.list_projects()

    {:noreply,
     socket
     |> stream(:projects, projects, reset: true)
     |> assign(:projects_empty?, projects == [])
     |> assign(:session_counts, Destila.Workflows.count_by_projects())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Helpers

  defp maybe_restream_project(socket, nil), do: socket

  defp maybe_restream_project(socket, project_id) do
    case Destila.Projects.get_project(project_id) do
      nil -> socket
      project -> stream_insert(socket, :projects, project)
    end
  end

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
          <h1 class="text-2xl font-bold tracking-tight">Projects</h1>
          <button
            :if={!@creating}
            phx-click="new_project"
            class="btn btn-primary btn-sm"
            id="new-project-btn"
          >
            <.icon name="hero-plus-micro" class="size-4" /> New Project
          </button>
        </div>

        <%!-- Create form --%>
        <div
          :if={@creating}
          class="card bg-base-100 shadow-sm mb-4"
          id="create-project-card"
        >
          <div class="card-body">
            <h3 class="text-sm font-semibold mb-3">New Project</h3>
            <.live_component
              module={DestilaWeb.ProjectFormLive}
              id="project-form-create"
              mode={:create}
            >
              <button phx-click="cancel" type="button" class="btn btn-ghost btn-sm flex-1">
                Cancel
              </button>
            </.live_component>
          </div>
        </div>

        <%!-- Project list --%>
        <div id="projects" phx-update="stream">
          <div class="hidden only:block text-center py-12" id="projects-empty">
            <.icon name="hero-folder" class="size-10 text-base-content/20 mx-auto mb-3" />
            <p class="text-sm text-base-content/30 mb-4">No projects yet</p>
            <button
              :if={!@creating}
              phx-click="new_project"
              class="btn btn-primary"
              id="create-first-project-btn"
            >
              <.icon name="hero-plus-micro" class="size-4" /> Create your first project
            </button>
          </div>

          <div
            :for={{id, project} <- @streams.projects}
            id={id}
            class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow mb-3"
          >
            <%!-- Edit form --%>
            <div :if={@editing_project_id == project.id} class="card-body">
              <h3 class="text-sm font-semibold mb-3">Edit Project</h3>
              <.live_component
                module={DestilaWeb.ProjectFormLive}
                id={"project-form-#{project.id}"}
                mode={:edit}
                project={project}
              >
                <button phx-click="cancel" type="button" class="btn btn-ghost btn-sm flex-1">
                  Cancel
                </button>
              </.live_component>
            </div>

            <%!-- Display --%>
            <div :if={@editing_project_id != project.id} class="card-body p-4 gap-2">
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
                    <span
                      :if={project.run_command}
                      class="text-xs text-base-content/40 truncate"
                    >
                      <.icon name="hero-play-micro" class="size-3.5 inline" />
                      {project.run_command}
                    </span>
                  </div>
                </div>

                <div class="flex items-center gap-1 ml-4 shrink-0">
                  <span class="text-xs text-base-content/40">
                    {linked_session_count(@session_counts, project.id)}
                  </span>

                  <button
                    phx-click="edit_project"
                    phx-value-id={project.id}
                    class="btn btn-ghost btn-xs opacity-60 hover:opacity-100 transition-opacity"
                    id={"edit-project-#{project.id}"}
                  >
                    <.icon name="hero-pencil-micro" class="size-4" />
                  </button>

                  <%= if @delete_confirming_id == project.id do %>
                    <button
                      phx-click="delete_project"
                      phx-value-id={project.id}
                      class="btn btn-error btn-xs"
                      id={"confirm-delete-#{project.id}"}
                    >
                      Delete
                    </button>
                    <button phx-click="cancel" class="btn btn-ghost btn-xs">
                      Cancel
                    </button>
                  <% else %>
                    <button
                      phx-click="confirm_delete"
                      phx-value-id={project.id}
                      class="btn btn-ghost btn-xs opacity-60 hover:opacity-100 transition-opacity text-error/60 hover:text-error"
                      id={"delete-project-#{project.id}"}
                    >
                      <.icon name="hero-trash-micro" class="size-4" />
                    </button>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
