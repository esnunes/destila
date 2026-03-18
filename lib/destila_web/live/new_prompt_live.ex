defmodule DestilaWeb.NewPromptLive do
  use DestilaWeb, :live_view

  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:current_user, session["current_user"])
     |> assign(:page_title, "New Prompt")
     |> assign(:step, 1)
     |> assign(:workflow_type, nil)}
  end

  def handle_event("select_type", %{"type" => type}, socket) do
    {:noreply,
     socket
     |> assign(:workflow_type, String.to_existing_atom(type))
     |> assign(:step, 2)}
  end

  def handle_event("set_repo", %{"repo_url" => repo_url}, socket) do
    create_and_redirect(socket, repo_url)
  end

  def handle_event("skip_repo", _params, socket) do
    create_and_redirect(socket, nil)
  end

  def handle_event("back", _params, socket) do
    {:noreply, assign(socket, step: 1, workflow_type: nil)}
  end

  defp create_and_redirect(socket, repo_url) do
    url = if repo_url && repo_url != "", do: repo_url, else: nil

    prompt =
      Destila.Store.create_prompt(%{
        title: default_title(socket.assigns.workflow_type),
        workflow_type: socket.assigns.workflow_type,
        repo_url: url,
        board: :crafting,
        column: :request,
        steps_completed: 0,
        steps_total: Destila.Workflows.total_steps(socket.assigns.workflow_type)
      })

    {:noreply, push_navigate(socket, to: ~p"/prompts/#{prompt.id}")}
  end

  defp default_title(:feature_request), do: "New Feature Request"
  defp default_title(:project), do: "New Project"

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="flex items-center justify-center min-h-[calc(100vh-4rem)]">
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
        </div>
      </div>
    </Layouts.app>
    """
  end
end
