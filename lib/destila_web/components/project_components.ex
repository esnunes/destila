defmodule DestilaWeb.ProjectComponents do
  @moduledoc """
  Shared function components for project selection and creation.
  Used by CreateSessionLive.
  """

  use Phoenix.Component
  import DestilaWeb.CoreComponents, only: [icon: 1]

  attr :projects, :list, required: true
  attr :selected_id, :string, default: nil
  attr :step, :atom, default: :select
  attr :form, :map, default: nil
  attr :errors, :map, default: %{}
  attr :target, :any, required: true

  def project_selector(assigns) do
    ~H"""
    <%!-- Project selection --%>
    <div :if={@step == :select}>
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
            phx-target={@target}
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
            phx-target={@target}
            id={"project-#{project.id}"}
            class={[
              "w-full text-left p-3 rounded-lg border-2 transition-colors cursor-pointer",
              if(@selected_id == project.id,
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
          phx-target={@target}
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
    <div :if={@step == :create}>
      <div class="mb-4">
        <h2 class="text-lg font-bold">Create a new project</h2>
        <p class="text-sm text-base-content/50 mt-1">
          Add a name and at least a git URL or local folder
        </p>
      </div>

      <form
        phx-submit="create_and_select_project"
        phx-target={@target}
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
            value={@form["name"].value}
            placeholder="My Project"
            aria-invalid={@errors[:name] && "true"}
            phx-mounted={Phoenix.LiveView.JS.focus()}
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
              value={@form["git_repo_url"].value}
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
              value={@form["local_folder"].value}
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
        phx-target={@target}
        class="btn btn-ghost btn-sm w-full mt-2 text-base-content/40"
      >
        &larr; Back to selection
      </button>
    </div>
    """
  end
end
