defmodule DestilaWeb.ProjectsLive do
  use DestilaWeb, :live_view

  def mount(_params, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
    end

    projects = Destila.Store.list_projects()

    {:ok,
     socket
     |> assign(:current_user, session["current_user"])
     |> assign(:page_title, "Projects")
     |> stream(:projects, projects)
     |> assign(:projects_empty?, projects == [])
     |> assign(:creating, false)
     |> assign(:editing_project_id, nil)
     |> assign(:form, new_form())
     |> assign(:delete_confirming_id, nil)}
  end

  def handle_event("new_project", _params, socket) do
    {:noreply,
     socket
     |> assign(:creating, true)
     |> assign(:editing_project_id, nil)
     |> assign(:form, new_form())}
  end

  def handle_event("cancel", _params, socket) do
    # Re-stream affected projects so stream items re-render
    socket =
      socket
      |> maybe_restream_project(socket.assigns.editing_project_id)
      |> maybe_restream_project(socket.assigns.delete_confirming_id)
      |> assign(:creating, false)
      |> assign(:editing_project_id, nil)
      |> assign(:delete_confirming_id, nil)

    {:noreply, socket}
  end

  def handle_event("create_project", params, socket) do
    case validate_project_params(params) do
      {:ok, attrs} ->
        Destila.Store.create_project(attrs)

        {:noreply,
         socket
         |> assign(:creating, false)
         |> assign(:form, new_form())}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("edit_project", %{"id" => id}, socket) do
    project = Destila.Store.get_project(id)

    if project do
      form =
        to_form(%{
          "name" => project.name,
          "git_repo_url" => project.git_repo_url || "",
          "local_folder" => project.local_folder || ""
        })

      {:noreply,
       socket
       |> stream_insert(:projects, project)
       |> assign(:editing_project_id, id)
       |> assign(:creating, false)
       |> assign(:form, form)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_project", params, socket) do
    id = socket.assigns.editing_project_id

    case validate_project_params(params) do
      {:ok, attrs} ->
        Destila.Store.update_project(id, attrs)

        {:noreply,
         socket
         |> assign(:editing_project_id, nil)
         |> assign(:form, new_form())}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    project = Destila.Store.get_project(id)

    socket =
      if project do
        stream_insert(socket, :projects, project)
      else
        socket
      end

    {:noreply, assign(socket, :delete_confirming_id, id)}
  end

  def handle_event("delete_project", %{"id" => id}, socket) do
    case Destila.Store.delete_project(id) do
      :ok ->
        {:noreply, assign(socket, :delete_confirming_id, nil)}

      {:error, :has_linked_prompts} ->
        {:noreply,
         socket
         |> maybe_restream_project(id)
         |> assign(:delete_confirming_id, nil)
         |> put_flash(:error, "Cannot delete project while it is linked to prompts")}

      {:error, :not_found} ->
        {:noreply, assign(socket, :delete_confirming_id, nil)}
    end
  end

  # PubSub handlers

  def handle_info({:project_created, _project}, socket) do
    projects = Destila.Store.list_projects()

    {:noreply,
     socket
     |> stream(:projects, projects, reset: true)
     |> assign(:projects_empty?, projects == [])}
  end

  def handle_info({:project_updated, _project}, socket) do
    projects = Destila.Store.list_projects()

    {:noreply,
     socket
     |> stream(:projects, projects, reset: true)
     |> assign(:projects_empty?, projects == [])}
  end

  def handle_info({:project_deleted, _project}, socket) do
    projects = Destila.Store.list_projects()

    {:noreply,
     socket
     |> stream(:projects, projects, reset: true)
     |> assign(:projects_empty?, projects == [])}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Helpers

  defp maybe_restream_project(socket, nil), do: socket

  defp maybe_restream_project(socket, project_id) do
    case Destila.Store.get_project(project_id) do
      nil -> socket
      project -> stream_insert(socket, :projects, project)
    end
  end

  defp new_form do
    to_form(%{"name" => "", "git_repo_url" => "", "local_folder" => ""})
  end

  defp validate_project_params(params) do
    name = String.trim(params["name"] || "")
    git_repo_url = params["git_repo_url"]
    git_repo_url = if git_repo_url && git_repo_url != "", do: git_repo_url, else: nil
    local_folder = params["local_folder"]
    local_folder = if local_folder && local_folder != "", do: local_folder, else: nil

    cond do
      name == "" ->
        {:error, "Project name is required"}

      git_repo_url == nil && local_folder == nil ->
        {:error, "At least a git repository URL or local folder is required"}

      true ->
        {:ok, %{name: name, git_repo_url: git_repo_url, local_folder: local_folder}}
    end
  end

  defp linked_prompt_count(project_id) do
    Destila.Store.list_prompts()
    |> Enum.count(&(&1[:project_id] == project_id))
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} page_title={@page_title}>
      <div class="p-6 lg:p-8 max-w-3xl mx-auto">
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
            <.project_form form={@form} submit_event="create_project" submit_label="Create" />
            <button phx-click="cancel" class="btn btn-ghost btn-sm mt-2">Cancel</button>
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
            class="card bg-base-100 shadow-sm mb-3"
          >
            <%!-- Edit form --%>
            <div :if={@editing_project_id == project.id} class="card-body">
              <h3 class="text-sm font-semibold mb-3">Edit Project</h3>
              <.project_form form={@form} submit_event="update_project" submit_label="Save" />
              <button phx-click="cancel" class="btn btn-ghost btn-sm mt-2">Cancel</button>
            </div>

            <%!-- Display --%>
            <div :if={@editing_project_id != project.id} class="card-body">
              <div class="flex items-start justify-between">
                <div class="min-w-0 flex-1">
                  <h3 class="font-semibold">{project.name}</h3>
                  <div class="flex flex-col gap-0.5 mt-1">
                    <span :if={project.git_repo_url} class="text-xs text-base-content/40 truncate">
                      <.icon name="hero-link-micro" class="size-3 inline" /> {project.git_repo_url}
                    </span>
                    <span :if={project.local_folder} class="text-xs text-base-content/40 truncate">
                      <.icon name="hero-folder-micro" class="size-3 inline" /> {project.local_folder}
                    </span>
                  </div>
                  <span class="text-xs text-base-content/30 mt-1">
                    {linked_prompt_count(project.id)} linked prompt(s)
                  </span>
                </div>

                <div class="flex items-center gap-1 ml-4 shrink-0">
                  <button
                    phx-click="edit_project"
                    phx-value-id={project.id}
                    class="btn btn-ghost btn-xs"
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
                      Confirm
                    </button>
                    <button phx-click="cancel" class="btn btn-ghost btn-xs">
                      Cancel
                    </button>
                  <% else %>
                    <button
                      phx-click="confirm_delete"
                      phx-value-id={project.id}
                      class="btn btn-ghost btn-xs text-error/60 hover:text-error"
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

  attr :form, :any, required: true
  attr :submit_event, :string, required: true
  attr :submit_label, :string, required: true

  defp project_form(assigns) do
    ~H"""
    <form phx-submit={@submit_event} class="space-y-3" id={"project-form-#{@submit_event}"}>
      <fieldset class="fieldset">
        <label class="fieldset-label text-xs font-medium" for="project-name">
          Name <span class="text-error">*</span>
        </label>
        <input
          type="text"
          id="project-name"
          name="name"
          value={@form["name"].value}
          placeholder="My Project"
          class="input input-bordered w-full input-sm"
        />
      </fieldset>

      <fieldset class="fieldset">
        <label class="fieldset-label text-xs font-medium" for="project-git-repo-url">
          Git repository URL
        </label>
        <input
          type="url"
          id="project-git-repo-url"
          name="git_repo_url"
          value={@form["git_repo_url"].value}
          placeholder="https://github.com/org/repo"
          class="input input-bordered w-full input-sm"
        />
      </fieldset>

      <fieldset class="fieldset">
        <label class="fieldset-label text-xs font-medium" for="project-local-folder">
          Local folder
        </label>
        <input
          type="text"
          id="project-local-folder"
          name="local_folder"
          value={@form["local_folder"].value}
          placeholder="/path/to/project"
          class="input input-bordered w-full input-sm"
        />
      </fieldset>

      <button type="submit" class="btn btn-primary btn-sm w-full">
        {@submit_label}
      </button>
    </form>
    """
  end
end
