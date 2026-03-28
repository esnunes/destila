defmodule DestilaWeb.Phases.WizardPhase do
  @moduledoc """
  LiveComponent for Phase 1 of workflows that need project selection
  and initial idea collection before creating a workflow session.
  """

  use DestilaWeb, :live_component

  def mount(socket) do
    {:ok,
     socket
     |> assign(:projects, Destila.Projects.list_projects())
     |> assign(:project_id, nil)
     |> assign(:project_step, :select)
     |> assign(
       :project_form,
       to_form(%{"name" => "", "git_repo_url" => "", "local_folder" => ""})
     )
     |> assign(:initial_idea, "")
     |> assign(:errors, %{})}
  end

  def update(assigns, socket) do
    {:ok,
     assign(socket,
       opts: assigns.opts,
       phase_number: assigns.phase_number,
       workflow_type: assigns.workflow_type,
       workflow: assigns.workflow
     )}
  end

  # --- Event handlers ---

  def handle_event("select_project", %{"id" => project_id}, socket) do
    {:noreply, assign(socket, project_id: project_id, errors: %{})}
  end

  def handle_event("show_create_project", _params, socket) do
    {:noreply, assign(socket, project_step: :create, errors: %{})}
  end

  def handle_event("back_to_select", _params, socket) do
    {:noreply, assign(socket, :project_step, :select)}
  end

  def handle_event("create_and_select_project", params, socket) do
    name = String.trim(params["name"] || "")
    git_repo_url = non_blank(params["git_repo_url"])
    local_folder = non_blank(params["local_folder"])

    errors = %{}
    errors = if name == "", do: Map.put(errors, :name, "Name is required"), else: errors

    errors =
      if git_repo_url == nil && local_folder == nil,
        do: Map.put(errors, :location, "Provide at least one"),
        else: errors

    if errors == %{} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: name,
          git_repo_url: git_repo_url,
          local_folder: local_folder
        })

      {:noreply,
       socket
       |> assign(:project_id, project.id)
       |> assign(:projects, Destila.Projects.list_projects())
       |> assign(:project_step, :select)
       |> assign(:errors, %{})}
    else
      {:noreply,
       socket
       |> assign(:project_form, to_form(params))
       |> assign(:errors, errors)}
    end
  end

  def handle_event("update_idea", %{"initial_idea" => idea}, socket) do
    errors =
      if idea != "",
        do: Map.delete(socket.assigns.errors, :idea),
        else: socket.assigns.errors

    {:noreply, assign(socket, initial_idea: idea, errors: errors)}
  end

  def handle_event("start_workflow", %{"initial_idea" => idea}, socket) when idea != "" do
    workflow = socket.assigns.workflow

    case workflow.wizard_validate_fields(%{
           project_id: socket.assigns.project_id,
           idea: idea
         }) do
      :ok ->
        session_attrs = %{
          title: workflow.default_title(),
          workflow_type: socket.assigns.workflow_type,
          current_phase: 2,
          total_phases: workflow.total_phases(),
          project_id: socket.assigns.project_id,
          title_generating: true
        }

        send(
          self(),
          {:phase_complete, socket.assigns.phase_number,
           %{
             action: :session_create,
             session_attrs: session_attrs,
             idea: idea
           }}
        )

        {:noreply, socket}

      {:error, errors} ->
        {:noreply, assign(socket, :errors, errors)}
    end
  end

  def handle_event("start_workflow", _params, socket) do
    {:noreply, assign(socket, :errors, %{idea: "Please describe your initial idea"})}
  end

  # --- Render ---

  def render(assigns) do
    ~H"""
    <div class="overflow-y-auto h-full px-6 py-6">
      <div class="max-w-2xl mx-auto space-y-6">
        <%!-- Project selection --%>
        <div :if={@project_step == :select}>
          <div class="mb-4">
            <h2 class="text-lg font-bold">Link a project</h2>
            <p class="text-sm text-base-content/50 mt-1">
              Select the project this task belongs to
            </p>
          </div>

          <%= if @projects == [] do %>
            <div class="text-center py-8">
              <.icon name="hero-folder" class="size-10 text-base-content/20 mx-auto mb-3" />
              <p class="text-sm text-base-content/30 mb-4">No projects yet</p>
              <button
                phx-click="show_create_project"
                phx-target={@myself}
                class="btn btn-primary"
                id="create-first-project-btn"
              >
                <.icon name="hero-plus-micro" class="size-4" /> Create your first project
              </button>
            </div>
          <% else %>
            <div class="space-y-2 max-h-64 overflow-y-auto" id="project-list">
              <button
                :for={project <- @projects}
                phx-click="select_project"
                phx-value-id={project.id}
                phx-target={@myself}
                id={"project-#{project.id}"}
                class={[
                  "w-full text-left p-3 rounded-lg border-2 transition-colors cursor-pointer",
                  if(@project_id == project.id,
                    do: "border-primary bg-primary/5",
                    else: "border-base-300 hover:border-primary"
                  )
                ]}
              >
                <div class="font-medium text-sm">{project.name}</div>
                <div class="text-xs text-base-content/40 mt-0.5">
                  {project.git_repo_url || project.local_folder}
                </div>
              </button>
            </div>

            <button
              phx-click="show_create_project"
              phx-target={@myself}
              class="btn btn-ghost btn-sm w-full mt-2"
              id="create-new-project-btn"
            >
              <.icon name="hero-plus-micro" class="size-4" /> Create New Project
            </button>
          <% end %>

          <p :if={@errors[:project]} class="text-xs text-error text-center mt-2">
            {@errors[:project]}
          </p>
        </div>

        <%!-- Create project inline --%>
        <div :if={@project_step == :create}>
          <div class="mb-4">
            <h2 class="text-lg font-bold">Create a new project</h2>
            <p class="text-sm text-base-content/50 mt-1">
              Add a name and at least a git URL or local folder
            </p>
          </div>

          <form
            phx-submit="create_and_select_project"
            phx-target={@myself}
            class="space-y-4"
            id="inline-project-form"
          >
            <fieldset class="fieldset">
              <label class="fieldset-label text-xs font-medium" for="project-name">
                Project name <span class="text-error">*</span>
              </label>
              <input
                type="text"
                id="project-name"
                name="name"
                value={@project_form["name"].value}
                placeholder="My Project"
                aria-invalid={@errors[:name] && "true"}
                phx-mounted={JS.focus()}
                class={[
                  "input input-bordered w-full",
                  @errors[:name] && "input-error"
                ]}
              />
              <p :if={@errors[:name]} class="text-xs text-error mt-1">
                {@errors[:name]}
              </p>
            </fieldset>

            <div class={[
              "rounded-lg p-3 space-y-3",
              if(@errors[:location],
                do: "ring-1 ring-error/30 bg-error/5",
                else: "bg-base-200/50"
              )
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
                  value={@project_form["git_repo_url"].value}
                  placeholder="https://github.com/org/repo"
                  aria-invalid={@errors[:location] && "true"}
                  class={[
                    "input input-bordered w-full",
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
                  value={@project_form["local_folder"].value}
                  placeholder="/path/to/project"
                  aria-invalid={@errors[:location] && "true"}
                  class={[
                    "input input-bordered w-full",
                    @errors[:location] && "input-error"
                  ]}
                />
              </fieldset>

              <p :if={@errors[:location]} class="text-xs text-error">
                {@errors[:location]}
              </p>
            </div>

            <button type="submit" class="btn btn-primary w-full" id="create-and-select-btn">
              <.icon name="hero-plus-micro" class="size-4" /> Create & Select
            </button>
          </form>

          <button
            phx-click="back_to_select"
            phx-target={@myself}
            class="btn btn-ghost btn-sm w-full mt-2 text-base-content/40"
          >
            &larr; Back to selection
          </button>
        </div>

        <%!-- Idea input (always visible below project selection) --%>
        <div :if={@project_step == :select}>
          <div class="border-t border-base-300 pt-6">
            <div class="mb-4">
              <h2 class="text-lg font-bold">Describe your idea</h2>
              <p class="text-sm text-base-content/50 mt-1">
                What chore or task do you want to work on?
              </p>
            </div>

            <form
              id="wizard-idea-form"
              phx-submit="start_workflow"
              phx-change="update_idea"
              phx-target={@myself}
              class="space-y-4"
            >
              <fieldset class="fieldset">
                <textarea
                  id="initial_idea"
                  name="initial_idea"
                  rows="5"
                  placeholder="Describe your idea in as much detail as you'd like..."
                  aria-invalid={@errors[:idea] && "true"}
                  class={[
                    "textarea textarea-bordered w-full",
                    @errors[:idea] && "textarea-error"
                  ]}
                  phx-debounce="300"
                >{@initial_idea}</textarea>
                <p :if={@errors[:idea]} class="text-xs text-error mt-1">
                  {@errors[:idea]}
                </p>
              </fieldset>

              <button type="submit" class="btn btn-primary w-full" id="start-workflow-btn">
                <.icon name="hero-arrow-right-micro" class="size-4" /> Start
              </button>
            </form>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp non_blank(nil), do: nil
  defp non_blank(""), do: nil
  defp non_blank(str), do: str
end
