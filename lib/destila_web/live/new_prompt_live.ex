defmodule DestilaWeb.NewPromptLive do
  use DestilaWeb, :live_view

  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:current_user, session["current_user"])
     |> assign(:page_title, "New Prompt")
     |> assign(:step, 1)
     |> assign(:workflow_type, nil)
     |> assign(:project_id, nil)
     |> assign(:projects, Destila.Projects.list_projects())
     |> assign(:project_step, :select)
     |> assign(
       :project_form,
       to_form(%{"name" => "", "git_repo_url" => "", "local_folder" => ""})
     )
     |> assign(:initial_idea, "")
     |> assign(:return_to, "/crafting")
     |> assign(:errors, %{})}
  end

  def handle_params(params, _uri, socket) do
    return_to = params["from"] || socket.assigns.return_to
    {:noreply, assign(socket, :return_to, return_to)}
  end

  def handle_event("select_type", %{"type" => type}, socket) do
    {:noreply,
     socket
     |> assign(:workflow_type, String.to_existing_atom(type))
     |> assign(:step, 2)}
  end

  def handle_event("continue_project", _params, socket) do
    if socket.assigns.project_id == nil && socket.assigns.workflow_type != :project do
      {:noreply, assign(socket, :errors, %{project: "Please select a project"})}
    else
      {:noreply, assign(socket, step: 3, errors: %{})}
    end
  end

  def handle_event("skip_project", _params, %{assigns: %{workflow_type: :project}} = socket) do
    {:noreply, assign(socket, step: 3, project_id: nil)}
  end

  def handle_event("skip_project", _params, socket) do
    {:noreply, assign(socket, :errors, %{project: "Please select a project"})}
  end

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
    git_repo_url = params["git_repo_url"]
    git_repo_url = if git_repo_url && git_repo_url != "", do: git_repo_url, else: nil
    local_folder = params["local_folder"]
    local_folder = if local_folder && local_folder != "", do: local_folder, else: nil

    errors = %{}
    errors = if name == "", do: Map.put(errors, :name, "Name is required"), else: errors

    errors =
      if git_repo_url == nil && local_folder == nil do
        Map.put(errors, :location, "Provide at least one")
      else
        errors
      end

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

  def handle_event("back", _params, socket) do
    {:noreply,
     assign(socket,
       step: 1,
       workflow_type: nil,
       project_id: nil,
       project_step: :select,
       errors: %{}
     )}
  end

  def handle_event("back_to_project", _params, socket) do
    {:noreply, assign(socket, step: 2, errors: %{})}
  end

  def handle_event("update_idea", %{"initial_idea" => idea}, socket) do
    errors =
      if idea != "" do
        Map.delete(socket.assigns.errors, :idea)
      else
        socket.assigns.errors
      end

    {:noreply, assign(socket, initial_idea: idea, errors: errors)}
  end

  def handle_event("save_and_continue", %{"initial_idea" => idea}, socket)
      when idea != "" do
    prompt = create_prompt_with_idea(socket, idea, :continue)
    {:noreply, push_navigate(socket, to: ~p"/prompts/#{prompt.id}")}
  end

  def handle_event("save_and_continue", _params, socket) do
    {:noreply, assign(socket, :errors, %{idea: "Please describe your initial idea"})}
  end

  def handle_event("save_and_close", _params, socket) do
    idea = socket.assigns.initial_idea

    if idea != "" do
      create_prompt_with_idea(socket, idea, :close)
      {:noreply, push_navigate(socket, to: socket.assigns.return_to)}
    else
      {:noreply, assign(socket, :errors, %{idea: "Please describe your initial idea"})}
    end
  end

  defp create_prompt_with_idea(socket, idea, action) do
    workflow_type = socket.assigns.workflow_type
    steps = Destila.Workflows.steps(workflow_type)
    first_step = List.first(steps)

    {:ok, prompt} =
      Destila.Repo.transaction(fn ->
        {:ok, prompt} =
          Destila.Prompts.create_prompt(%{
            title: "Generating title...",
            title_generating: true,
            workflow_type: workflow_type,
            project_id: socket.assigns.project_id,
            board: :crafting,
            column: :request,
            steps_completed: 1,
            steps_total: Destila.Workflows.total_steps(workflow_type),
            phase_status: if(workflow_type == :chore_task, do: :generating, else: nil)
          })

        # Add system message for phase 1 (the question)
        {:ok, _} =
          Destila.Messages.create_message(prompt.id, %{
            role: :system,
            content: first_step.content,
            phase: 1
          })

        # Add user message for phase 1 (the initial idea)
        {:ok, _} =
          Destila.Messages.create_message(prompt.id, %{
            role: :user,
            content: idea,
            phase: 1
          })

        # For static workflows, add the second system message so the chat picks up from there
        # For AI-driven workflows (chore_task), skip — the AI will generate the next response
        if workflow_type != :chore_task do
          second_step = Enum.at(steps, 1)

          {:ok, _} =
            Destila.Messages.create_message(prompt.id, %{
              role: :system,
              content: second_step.content,
              phase: second_step.step
            })
        end

        prompt
      end)

    # Start an AI session registered to this prompt
    session_opts =
      case action do
        :continue -> [timeout_ms: :timer.minutes(15)]
        :close -> [timeout_ms: :timer.seconds(30)]
      end

    {:ok, session} = Destila.AI.Session.for_prompt(prompt.id, session_opts)

    # Generate title asynchronously
    prompt_id = prompt.id

    Task.Supervisor.start_child(Destila.TaskSupervisor, fn ->
      case Destila.AI.generate_title(session, workflow_type, idea) do
        {:ok, title} ->
          Destila.Prompts.update_prompt(prompt_id, %{title: title, title_generating: false})

        {:error, _} ->
          Destila.Prompts.update_prompt(prompt_id, %{
            title: default_title(workflow_type),
            title_generating: false
          })
      end

      # For AI-driven workflows on :continue, trigger the first AI response
      if workflow_type == :chore_task && action == :continue do
        trigger_ai_response(prompt_id, session, 1)
      end

      if action == :close do
        Destila.AI.Session.stop(session)
      end
    end)

    prompt
  end

  defp trigger_ai_response(prompt_id, session, phase) do
    prompt = Destila.Prompts.get_prompt!(prompt_id)
    messages = Destila.Messages.list_messages(prompt_id)

    system_prompt = Destila.Workflows.ChoreTaskPhases.system_prompt(phase, prompt)
    conversation_context = Destila.Workflows.ChoreTaskPhases.build_conversation_context(messages)

    query = system_prompt <> "\n\n" <> conversation_context

    Destila.Prompts.update_prompt(prompt_id, %{phase_status: :generating})

    case Destila.AI.Session.query(session, query) do
      {:ok, result} ->
        response_text = Destila.Messages.response_text(result)
        new_phase_status = Destila.Messages.derive_phase_status(response_text)

        {:ok, _} =
          Destila.Messages.create_message(prompt_id, %{
            role: :system,
            content: response_text,
            raw_response: result,
            phase: phase
          })

        # Persist session_id + phase_status
        update_attrs = %{phase_status: new_phase_status}

        update_attrs =
          if result[:session_id],
            do: Map.put(update_attrs, :session_id, result[:session_id]),
            else: update_attrs

        Destila.Prompts.update_prompt(prompt_id, update_attrs)

      {:error, _} ->
        {:ok, _} =
          Destila.Messages.create_message(prompt_id, %{
            role: :system,
            content: "Something went wrong. Please try sending your message again.",
            phase: phase
          })

        Destila.Prompts.update_prompt(prompt_id, %{phase_status: :conversing})
    end
  end

  defp default_title(:feature_request), do: "New Feature Request"
  defp default_title(:project), do: "New Project"
  defp default_title(:chore_task), do: "New Chore/Task"

  defp initial_idea_question(workflow_type) do
    steps = Destila.Workflows.steps(workflow_type)
    first_step = List.first(steps)
    first_step.content
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} page_title={@page_title}>
      <div class="flex items-center justify-center min-h-screen">
        <div class="w-full max-w-lg px-6">
          <%!-- Step indicator --%>
          <div class="flex items-center justify-center gap-2 mb-8">
            <div class={[
              "w-8 h-8 rounded-full flex items-center justify-center text-sm font-medium transition-colors",
              if(@step >= 1,
                do: "bg-primary text-primary-content",
                else: "bg-base-300 text-base-content/40"
              )
            ]}>
              1
            </div>
            <span class="w-8 h-0.5 bg-base-300" />
            <div class={[
              "w-8 h-8 rounded-full flex items-center justify-center text-sm font-medium transition-colors",
              if(@step >= 2,
                do: "bg-primary text-primary-content",
                else: "bg-base-300 text-base-content/40"
              )
            ]}>
              2
            </div>
            <span class="w-8 h-0.5 bg-base-300" />
            <div class={[
              "w-8 h-8 rounded-full flex items-center justify-center text-sm font-medium transition-colors",
              if(@step >= 3,
                do: "bg-primary text-primary-content",
                else: "bg-base-300 text-base-content/40"
              )
            ]}>
              3
            </div>
          </div>

          <%!-- Step 1: Pick workflow type --%>
          <div :if={@step == 1} class="space-y-4">
            <div class="text-center mb-6">
              <h2 class="text-xl font-bold">What are you creating?</h2>
              <p class="text-sm text-base-content/50 mt-1">Choose a workflow type to get started</p>
            </div>

            <div class="grid grid-cols-3 gap-4">
              <button
                phx-click="select_type"
                phx-value-type="feature_request"
                class="card bg-base-100 border-2 border-base-300 hover:border-primary transition-colors cursor-pointer text-left"
              >
                <div class="card-body p-5">
                  <.icon name="hero-light-bulb" class="size-8 text-info mb-2" />
                  <h3 class="font-semibold">Feature Request</h3>
                  <p class="text-xs text-base-content/50">
                    Describe a new feature or enhancement for an existing project
                  </p>
                </div>
              </button>

              <button
                phx-click="select_type"
                phx-value-type="chore_task"
                class="card bg-base-100 border-2 border-base-300 hover:border-primary transition-colors cursor-pointer text-left"
              >
                <div class="card-body p-5">
                  <.icon name="hero-wrench-screwdriver" class="size-8 text-warning mb-2" />
                  <h3 class="font-semibold">Chore / Task</h3>
                  <p class="text-xs text-base-content/50">
                    Straightforward coding tasks, bug fixes, or refactors
                  </p>
                </div>
              </button>

              <button
                phx-click="select_type"
                phx-value-type="project"
                class="card bg-base-100 border-2 border-base-300 hover:border-primary transition-colors cursor-pointer text-left"
              >
                <div class="card-body p-5">
                  <.icon name="hero-rocket-launch" class="size-8 text-secondary mb-2" />
                  <h3 class="font-semibold">Project</h3>
                  <p class="text-xs text-base-content/50">
                    Start a brand new project from scratch
                  </p>
                </div>
              </button>
            </div>
          </div>

          <%!-- Step 2: Link a project --%>
          <div :if={@step == 2} class="space-y-4">
            <%!-- Select existing project --%>
            <div :if={@project_step == :select}>
              <div class="text-center mb-6">
                <h2 class="text-xl font-bold">Link a project</h2>
                <p class="text-sm text-base-content/50 mt-1">
                  <%= if @workflow_type == :project do %>
                    Select a project to give context, or skip for new projects
                  <% else %>
                    Select the project this task belongs to
                  <% end %>
                </p>
              </div>

              <%= if @projects == [] do %>
                <div class="text-center py-8">
                  <.icon name="hero-folder" class="size-10 text-base-content/20 mx-auto mb-3" />
                  <p class="text-sm text-base-content/30 mb-4">No projects yet</p>
                  <button
                    phx-click="show_create_project"
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
                  class="btn btn-ghost btn-sm w-full mt-2"
                  id="create-new-project-btn"
                >
                  <.icon name="hero-plus-micro" class="size-4" /> Create New Project
                </button>
              <% end %>

              <p :if={@errors[:project]} class="text-xs text-error text-center mt-2">
                {@errors[:project]}
              </p>

              <div class="flex gap-3 mt-4">
                <button
                  phx-click="continue_project"
                  class="btn btn-primary flex-1"
                  id="continue-project-btn"
                >
                  Continue
                </button>
                <button
                  :if={@workflow_type == :project}
                  phx-click="skip_project"
                  class="btn btn-ghost flex-1"
                  id="skip-project-btn"
                >
                  Skip
                </button>
              </div>

              <button phx-click="back" class="btn btn-ghost btn-sm w-full mt-2 text-base-content/40">
                &larr; Back
              </button>
            </div>

            <%!-- Create new project inline --%>
            <div :if={@project_step == :create}>
              <div class="text-center mb-6">
                <h2 class="text-xl font-bold">Create a new project</h2>
                <p class="text-sm text-base-content/50 mt-1">
                  Add a name and at least a git URL or local folder
                </p>
              </div>

              <form
                phx-submit="create_and_select_project"
                class="space-y-4"
                id="inline-project-form"
                phx-hook="FocusFirstError"
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
                class="btn btn-ghost btn-sm w-full mt-2 text-base-content/40"
              >
                &larr; Back to selection
              </button>
            </div>
          </div>

          <%!-- Step 3: Initial idea --%>
          <div :if={@step == 3} class="space-y-4">
            <div class="text-center mb-6">
              <h2 class="text-xl font-bold">Describe your idea</h2>
              <p class="text-sm text-base-content/50 mt-1">
                {initial_idea_question(@workflow_type)}
              </p>
            </div>

            <form
              id="initial-idea-form"
              phx-submit="save_and_continue"
              phx-change="update_idea"
              phx-hook="FocusFirstError"
              class="space-y-4"
            >
              <fieldset class="fieldset">
                <label class="fieldset-label text-xs font-medium" for="initial_idea">
                  Your idea
                </label>
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
                />
                <p :if={@errors[:idea]} class="text-xs text-error mt-1">
                  {@errors[:idea]}
                </p>
              </fieldset>

              <div class="flex gap-3">
                <button type="submit" class="btn btn-primary flex-1">
                  <.icon name="hero-arrow-right-micro" class="size-4" /> Save & Continue
                </button>
                <button
                  type="button"
                  phx-click="save_and_close"
                  class="btn btn-ghost flex-1"
                  id="save-and-close-btn"
                >
                  <.icon name="hero-bookmark-micro" class="size-4" /> Save & Close
                </button>
              </div>
            </form>

            <button
              phx-click="back_to_project"
              class="btn btn-ghost btn-sm w-full mt-2 text-base-content/40"
            >
              &larr; Back
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
