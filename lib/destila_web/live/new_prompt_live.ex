defmodule DestilaWeb.NewPromptLive do
  use DestilaWeb, :live_view

  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:current_user, session["current_user"])
     |> assign(:page_title, "New Prompt")
     |> assign(:step, 1)
     |> assign(:workflow_type, nil)
     |> assign(:repo_url, nil)
     |> assign(:initial_idea, "")
     |> assign(:return_to, "/crafting")}
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

  def handle_event("set_repo", %{"repo_url" => repo_url}, socket) do
    url = if repo_url && repo_url != "", do: repo_url, else: nil
    {:noreply, assign(socket, step: 3, repo_url: url)}
  end

  def handle_event("skip_repo", _params, socket) do
    {:noreply, assign(socket, step: 3, repo_url: nil)}
  end

  def handle_event("back", _params, socket) do
    {:noreply, assign(socket, step: 1, workflow_type: nil)}
  end

  def handle_event("back_to_repo", _params, socket) do
    {:noreply, assign(socket, step: 2)}
  end

  def handle_event("update_idea", %{"initial_idea" => idea}, socket) do
    {:noreply, assign(socket, :initial_idea, idea)}
  end

  def handle_event("save_and_continue", %{"initial_idea" => idea}, socket)
      when idea != "" do
    prompt = create_prompt_with_idea(socket, idea, :continue)
    {:noreply, push_navigate(socket, to: ~p"/prompts/#{prompt.id}")}
  end

  def handle_event("save_and_continue", _params, socket) do
    {:noreply, put_flash(socket, :error, "Please describe your initial idea")}
  end

  def handle_event("save_and_close", _params, socket) do
    idea = socket.assigns.initial_idea

    if idea != "" do
      create_prompt_with_idea(socket, idea, :close)
      {:noreply, push_navigate(socket, to: socket.assigns.return_to)}
    else
      {:noreply, put_flash(socket, :error, "Please describe your initial idea")}
    end
  end

  defp create_prompt_with_idea(socket, idea, action) do
    workflow_type = socket.assigns.workflow_type
    steps = Destila.Workflows.steps(workflow_type)
    first_step = List.first(steps)

    prompt =
      Destila.Store.create_prompt(%{
        title: "Generating title...",
        title_generating: true,
        workflow_type: workflow_type,
        repo_url: socket.assigns.repo_url,
        board: :crafting,
        column: :request,
        steps_completed: 1,
        steps_total: Destila.Workflows.total_steps(workflow_type)
      })

    # Add system message for step 1 (the question)
    Destila.Store.add_message(prompt.id, %{
      role: :system,
      content: first_step.content,
      input_type: first_step.input_type,
      options: first_step.options,
      step: first_step.step
    })

    # Add user message for step 1 (the initial idea)
    Destila.Store.add_message(prompt.id, %{
      role: :user,
      content: idea,
      selected: nil,
      step: 1
    })

    # Add system message for step 2 (so the chat picks up from here)
    second_step = Enum.at(steps, 1)

    Destila.Store.add_message(prompt.id, %{
      role: :system,
      content: second_step.content,
      input_type: second_step.input_type,
      options: second_step.options,
      step: second_step.step
    })

    # Start an AI session and store its PID on the prompt
    session_opts =
      case action do
        :continue -> []
        :close -> [timeout_ms: :timer.seconds(30)]
      end

    {:ok, session} = Destila.AI.Session.start_link(session_opts)
    Destila.Store.update_prompt(prompt.id, %{ai_session: session})

    # Generate title asynchronously
    prompt_id = prompt.id

    Task.Supervisor.start_child(Destila.TaskSupervisor, fn ->
      case Destila.AI.generate_title(session, workflow_type, idea) do
        {:ok, title} ->
          Destila.Store.update_prompt(prompt_id, %{title: title, title_generating: false})

        {:error, _} ->
          Destila.Store.update_prompt(prompt_id, %{
            title: default_title(workflow_type),
            title_generating: false
          })
      end

      if action == :close do
        Destila.AI.Session.stop(session)
        Destila.Store.update_prompt(prompt_id, %{ai_session: nil})
      end
    end)

    prompt
  end

  defp default_title(:feature_request), do: "New Feature Request"
  defp default_title(:project), do: "New Project"

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

            <div class="grid grid-cols-2 gap-4">
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

          <%!-- Step 2: Link repository --%>
          <div :if={@step == 2} class="space-y-4">
            <div class="text-center mb-6">
              <h2 class="text-xl font-bold">Link a repository</h2>
              <p class="text-sm text-base-content/50 mt-1">
                Paste a repository URL to give context, or skip for new projects
              </p>
            </div>

            <form phx-submit="set_repo" class="space-y-4">
              <fieldset class="fieldset">
                <label class="fieldset-label text-xs font-medium" for="repo_url">
                  Repository URL
                </label>
                <input
                  type="url"
                  id="repo_url"
                  name="repo_url"
                  placeholder="https://github.com/org/repo"
                  class="input input-bordered w-full"
                />
              </fieldset>

              <div class="flex gap-3">
                <button type="submit" class="btn btn-primary flex-1">
                  Continue
                </button>
                <button type="button" phx-click="skip_repo" class="btn btn-ghost flex-1">
                  Skip
                </button>
              </div>
            </form>

            <button phx-click="back" class="btn btn-ghost btn-sm w-full mt-2 text-base-content/40">
              &larr; Back
            </button>
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
                  class="textarea textarea-bordered w-full"
                  phx-debounce="300"
                />
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
              phx-click="back_to_repo"
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
