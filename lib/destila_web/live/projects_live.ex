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
     |> assign(:form, new_form())
     |> assign(:errors, %{})
     |> assign(:port_definitions, [])
     |> assign(:delete_confirming_id, nil)}
  end

  def handle_event("new_project", _params, socket) do
    {:noreply,
     socket
     |> assign(:creating, true)
     |> assign(:editing_project_id, nil)
     |> assign(:form, new_form())
     |> assign(:errors, %{})
     |> assign(:port_definitions, [])}
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
      |> assign(:errors, %{})
      |> assign(:port_definitions, [])

    {:noreply, socket}
  end

  def handle_event("create_project", params, socket) do
    case validate_project_params(params, socket.assigns.port_definitions) do
      {:ok, attrs} ->
        {:ok, _project} = Destila.Projects.create_project(attrs)

        {:noreply,
         socket
         |> assign(:creating, false)
         |> assign(:form, new_form())
         |> assign(:errors, %{})
         |> assign(:port_definitions, [])}

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(:form, to_form(params))
         |> assign(:errors, errors)}
    end
  end

  def handle_event("edit_project", %{"id" => id}, socket) do
    project = Destila.Projects.get_project(id)

    if project do
      form =
        to_form(%{
          "name" => project.name,
          "git_repo_url" => project.git_repo_url || "",
          "local_folder" => project.local_folder || "",
          "run_command" => project.run_command || ""
        })

      {:noreply,
       socket
       |> stream_insert(:projects, project)
       |> assign(:editing_project_id, id)
       |> assign(:creating, false)
       |> assign(:form, form)
       |> assign(:errors, %{})
       |> assign(:port_definitions, project.port_definitions)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_project", params, socket) do
    id = socket.assigns.editing_project_id

    case validate_project_params(params, socket.assigns.port_definitions) do
      {:ok, attrs} ->
        project = Destila.Projects.get_project!(id)
        {:ok, _project} = Destila.Projects.update_project(project, attrs)

        {:noreply,
         socket
         |> assign(:editing_project_id, nil)
         |> assign(:form, new_form())
         |> assign(:errors, %{})
         |> assign(:port_definitions, [])}

      {:error, errors} ->
        project = Destila.Projects.get_project(id)

        {:noreply,
         socket
         |> then(fn s -> if project, do: stream_insert(s, :projects, project), else: s end)
         |> assign(:form, to_form(params))
         |> assign(:errors, errors)}
    end
  end

  def handle_event("validate_form", params, socket) do
    port_definitions =
      params
      |> Enum.filter(fn {k, _} -> String.starts_with?(k, "port_def_") end)
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {_, v} -> v end)

    port_definitions =
      if port_definitions == [], do: socket.assigns.port_definitions, else: port_definitions

    {:noreply,
     socket
     |> assign(:form, to_form(params))
     |> assign(:port_definitions, port_definitions)}
  end

  def handle_event("add_port", _params, socket) do
    {:noreply, assign(socket, :port_definitions, socket.assigns.port_definitions ++ [""])}
  end

  def handle_event("remove_port", %{"index" => index}, socket) do
    index = String.to_integer(index)
    port_definitions = List.delete_at(socket.assigns.port_definitions, index)
    {:noreply, assign(socket, :port_definitions, port_definitions)}
  end

  def handle_event("update_port", params, socket) do
    index = String.to_integer(params["index"])
    value = params["value"] || ""
    port_definitions = List.replace_at(socket.assigns.port_definitions, index, value)
    {:noreply, assign(socket, :port_definitions, port_definitions)}
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

  defp new_form do
    to_form(%{"name" => "", "git_repo_url" => "", "local_folder" => "", "run_command" => ""})
  end

  defp validate_project_params(params, port_definitions) do
    name = String.trim(params["name"] || "")
    git_repo_url = params["git_repo_url"]
    git_repo_url = if git_repo_url && git_repo_url != "", do: git_repo_url, else: nil
    local_folder = params["local_folder"]
    local_folder = if local_folder && local_folder != "", do: local_folder, else: nil
    run_command = params["run_command"]
    run_command = if run_command && run_command != "", do: run_command, else: nil

    # Filter empty port definitions
    port_defs = Enum.reject(port_definitions, &(&1 == ""))

    errors = %{}
    errors = if name == "", do: Map.put(errors, :name, "Name is required"), else: errors

    errors =
      if git_repo_url == nil && local_folder == nil do
        Map.put(errors, :location, "Provide at least one")
      else
        errors
      end

    # Validate port definitions format
    errors =
      Enum.reduce(port_defs, errors, fn pd, acc ->
        if Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, pd) do
          acc
        else
          Map.put(
            acc,
            :port_definitions,
            "#{pd} is not a valid env var name (use uppercase, e.g. PORT)"
          )
        end
      end)

    if errors == %{} do
      {:ok,
       %{
         name: name,
         git_repo_url: git_repo_url,
         local_folder: local_folder,
         run_command: run_command,
         port_definitions: port_defs
       }}
    else
      {:error, errors}
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
            <.project_form
              form={@form}
              errors={@errors}
              submit_event="create_project"
              submit_label="Create"
              port_definitions={@port_definitions}
            >
              <button phx-click="cancel" type="button" class="btn btn-ghost btn-sm flex-1">
                Cancel
              </button>
            </.project_form>
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
              <.project_form
                form={@form}
                errors={@errors}
                submit_event="update_project"
                submit_label="Save"
                port_definitions={@port_definitions}
              >
                <button phx-click="cancel" type="button" class="btn btn-ghost btn-sm flex-1">
                  Cancel
                </button>
              </.project_form>
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

  attr :form, :any, required: true
  attr :errors, :map, required: true
  attr :submit_event, :string, required: true
  attr :submit_label, :string, required: true
  attr :port_definitions, :list, required: true
  slot :inner_block

  defp project_form(assigns) do
    ~H"""
    <form
      phx-submit={@submit_event}
      phx-change="validate_form"
      class="space-y-3"
      id={"project-form-#{@submit_event}"}
      phx-hook="FocusFirstError"
    >
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
          aria-invalid={@errors[:name] && "true"}
          phx-mounted={JS.focus()}
          class={[
            "input input-bordered w-full input-sm",
            @errors[:name] && "input-error"
          ]}
        />
        <p :if={@errors[:name]} class="text-xs text-error mt-1">{@errors[:name]}</p>
      </fieldset>

      <div class={[
        "rounded-lg p-3 space-y-3",
        if(@errors[:location], do: "ring-1 ring-error/30 bg-error/5", else: "bg-base-200/50")
      ]}>
        <div class="flex items-center gap-2">
          <span class="text-xs font-medium text-base-content/50">Location</span>
          <span class="text-xs text-base-content/30">at least one required</span>
        </div>

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
            aria-invalid={@errors[:location] && "true"}
            class={[
              "input input-bordered w-full input-sm",
              @errors[:location] && "input-error"
            ]}
          />
        </fieldset>

        <div class="flex items-center gap-3">
          <div class="flex-1 h-px bg-base-300" />
          <span class="text-xs text-base-content/30">or</span>
          <div class="flex-1 h-px bg-base-300" />
        </div>

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
            aria-invalid={@errors[:location] && "true"}
            class={[
              "input input-bordered w-full input-sm",
              @errors[:location] && "input-error"
            ]}
          />
        </fieldset>

        <p :if={@errors[:location]} class="text-xs text-error">{@errors[:location]}</p>
      </div>

      <div class="rounded-lg p-3 space-y-3 bg-base-200/50">
        <div class="flex items-center gap-2">
          <span class="text-xs font-medium text-base-content/50">Service</span>
          <span class="text-xs text-base-content/30">optional</span>
        </div>

        <fieldset class="fieldset">
          <label class="fieldset-label text-xs font-medium" for="project-run-command">
            Run command
          </label>
          <input
            type="text"
            id="project-run-command"
            name="run_command"
            value={@form["run_command"].value}
            placeholder="mix setup && mix phx.server"
            class="input input-bordered w-full input-sm"
          />
        </fieldset>

        <div>
          <div class="flex items-center justify-between mb-2">
            <label class="text-xs font-medium text-base-content/70">Port definitions</label>
            <button
              type="button"
              phx-click="add_port"
              class="btn btn-ghost btn-xs"
              id="add-port-btn"
            >
              <.icon name="hero-plus-micro" class="size-3" /> Add port
            </button>
          </div>

          <div :if={@port_definitions != []} class="space-y-2">
            <div
              :for={{pd, idx} <- Enum.with_index(@port_definitions)}
              class="flex items-center gap-2"
              id={"port-def-#{idx}"}
            >
              <input
                type="text"
                name={"port_def_#{idx}"}
                value={pd}
                placeholder="PORT"
                phx-blur="update_port"
                phx-value-index={idx}
                class={[
                  "input input-bordered w-full input-sm font-mono uppercase",
                  @errors[:port_definitions] && "input-error"
                ]}
                id={"port-input-#{idx}"}
              />
              <button
                type="button"
                phx-click="remove_port"
                phx-value-index={idx}
                class="btn btn-ghost btn-xs text-error/60 hover:text-error"
                id={"remove-port-#{idx}"}
              >
                <.icon name="hero-x-mark-micro" class="size-4" />
              </button>
            </div>
          </div>

          <p :if={@errors[:port_definitions]} class="text-xs text-error mt-1">
            {@errors[:port_definitions]}
          </p>
        </div>
      </div>

      <div class="flex gap-2">
        <button type="submit" class="btn btn-primary btn-sm flex-1">
          {@submit_label}
        </button>
        {render_slot(@inner_block)}
      </div>
    </form>
    """
  end
end
