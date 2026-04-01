defmodule DestilaWeb.Phases.PromptWizardPhase do
  @moduledoc """
  LiveComponent for Phase 1 of the Implement General Prompt workflow.
  Combines prompt selection (from existing sessions or manual entry)
  with project selection on a single screen.
  """

  use DestilaWeb, :live_component

  def mount(socket) do
    sessions_with_prompts = Destila.Workflows.list_sessions_with_generated_prompts()

    {:ok,
     socket
     |> assign(:sessions_with_prompts, sessions_with_prompts)
     |> assign(:selected_session_id, nil)
     |> assign(:selected_prompt, nil)
     |> assign(:prompt_mode, :select)
     |> assign(:manual_prompt, "")
     |> assign(:projects, Destila.Projects.list_projects())
     |> assign(:project_id, nil)
     |> assign(:project_step, :select)
     |> assign(
       :project_form,
       to_form(%{"name" => "", "git_repo_url" => "", "local_folder" => ""})
     )
     |> assign(:errors, %{})}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, opts: assigns.opts, phase_number: assigns.phase_number)}
  end

  # --- Prompt selection events ---

  def handle_event("select_session", %{"id" => session_id}, socket) do
    case Enum.find(socket.assigns.sessions_with_prompts, fn {ws, _} -> ws.id == session_id end) do
      nil ->
        {:noreply, socket}

      {ws, prompt} ->
        project_id = if ws.project_id, do: ws.project_id, else: socket.assigns.project_id

        {:noreply,
         socket
         |> assign(:selected_session_id, session_id)
         |> assign(:selected_prompt, prompt)
         |> assign(:project_id, project_id)
         |> assign(:prompt_mode, :select)
         |> assign(:errors, Map.delete(socket.assigns.errors, :prompt))}
    end
  end

  def handle_event("switch_to_manual", _params, socket) do
    {:noreply,
     socket
     |> assign(:prompt_mode, :manual)
     |> assign(:selected_session_id, nil)
     |> assign(:selected_prompt, nil)}
  end

  def handle_event("switch_to_select", _params, socket) do
    {:noreply, assign(socket, :prompt_mode, :select)}
  end

  def handle_event("update_prompt", %{"manual_prompt" => prompt}, socket) do
    errors =
      if prompt != "",
        do: Map.delete(socket.assigns.errors, :prompt),
        else: socket.assigns.errors

    {:noreply, assign(socket, manual_prompt: prompt, errors: errors)}
  end

  # --- Project selection events (delegated to shared component) ---

  def handle_event("select_project", %{"id" => project_id}, socket) do
    {:noreply,
     assign(socket, project_id: project_id, errors: Map.delete(socket.assigns.errors, :project))}
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

  # --- Start workflow ---

  def handle_event("start_workflow", _params, socket) do
    prompt = resolve_prompt(socket.assigns)
    errors = validate(socket.assigns, prompt)

    if errors == %{} do
      send(
        self(),
        {:phase_complete, socket.assigns.phase_number,
         %{
           action: :session_create,
           project_id: socket.assigns.project_id,
           prompt: prompt,
           selected_session_id: socket.assigns.selected_session_id,
           title_generating: is_nil(socket.assigns.selected_session_id)
         }}
      )

      {:noreply, socket}
    else
      {:noreply, assign(socket, :errors, errors)}
    end
  end

  # --- Render ---

  def render(assigns) do
    ~H"""
    <div class="overflow-y-auto h-full px-6 py-6">
      <div class="max-w-2xl mx-auto space-y-6">
        <%!-- Prompt section --%>
        <div>
          <div class="mb-4">
            <h2 class="text-lg font-bold">Choose a prompt</h2>
            <p class="text-sm text-base-content/50 mt-1">
              Select from a completed session or write your own
            </p>
          </div>

          <%!-- Prompt mode tabs --%>
          <div class="flex gap-2 mb-4">
            <button
              phx-click="switch_to_select"
              phx-target={@myself}
              class={[
                "btn btn-sm",
                if(@prompt_mode == :select, do: "btn-primary", else: "btn-ghost")
              ]}
              id="tab-select-prompt"
            >
              Select existing
            </button>
            <button
              phx-click="switch_to_manual"
              phx-target={@myself}
              class={[
                "btn btn-sm",
                if(@prompt_mode == :manual, do: "btn-primary", else: "btn-ghost")
              ]}
              id="tab-manual-prompt"
            >
              Write manually
            </button>
          </div>

          <%!-- Select from existing sessions --%>
          <div :if={@prompt_mode == :select}>
            <%= if @sessions_with_prompts == [] do %>
              <div class="text-center py-8">
                <.icon name="hero-document-text" class="size-10 text-base-content/20 mx-auto mb-3" />
                <p class="text-sm text-base-content/30 mb-2">No completed prompts yet</p>
                <p class="text-xs text-base-content/20">
                  Complete a Brainstorm Idea workflow first, or write a prompt manually
                </p>
              </div>
            <% else %>
              <div class="space-y-2 max-h-64 overflow-y-auto" id="session-prompt-list">
                <button
                  :for={{ws, prompt} <- @sessions_with_prompts}
                  phx-click="select_session"
                  phx-value-id={ws.id}
                  phx-target={@myself}
                  id={"session-#{ws.id}"}
                  class={[
                    "w-full text-left p-3 rounded-lg border-2 transition-colors cursor-pointer",
                    if(@selected_session_id == ws.id,
                      do: "border-primary bg-primary/5",
                      else: "border-base-300 hover:border-primary"
                    )
                  ]}
                >
                  <div class="font-medium text-sm">{ws.title}</div>
                  <div class="text-xs text-base-content/40 mt-1 line-clamp-2">
                    {String.slice(prompt, 0, 200)}
                  </div>
                </button>
              </div>
            <% end %>
          </div>

          <%!-- Manual prompt input --%>
          <div :if={@prompt_mode == :manual}>
            <form
              id="manual-prompt-form"
              phx-change="update_prompt"
              phx-target={@myself}
            >
              <textarea
                id="manual_prompt"
                name="manual_prompt"
                rows="8"
                placeholder="Describe what you want to implement..."
                aria-invalid={@errors[:prompt] && "true"}
                class={[
                  "textarea textarea-bordered w-full",
                  @errors[:prompt] && "textarea-error"
                ]}
                phx-debounce="300"
              >{@manual_prompt}</textarea>
            </form>
          </div>

          <p :if={@errors[:prompt]} class="text-xs text-error mt-2">
            {@errors[:prompt]}
          </p>
        </div>

        <%!-- Project section --%>
        <div class="border-t border-base-300 pt-6">
          <.project_selector
            projects={@projects}
            selected_id={@project_id}
            step={@project_step}
            form={@project_form}
            errors={@errors}
            target={@myself}
          />
        </div>

        <%!-- Start button --%>
        <div :if={@project_step == :select}>
          <button
            phx-click="start_workflow"
            phx-target={@myself}
            class="btn btn-primary w-full"
            id="start-workflow-btn"
          >
            <.icon name="hero-rocket-launch-micro" class="size-4" /> Start Implementation
          </button>
        </div>
      </div>
    </div>
    """
  end

  # --- Private helpers ---

  defp resolve_prompt(assigns) do
    case assigns.prompt_mode do
      :select -> assigns.selected_prompt
      :manual -> String.trim(assigns.manual_prompt)
    end
  end

  defp validate(assigns, prompt) do
    errors = %{}

    errors =
      if is_nil(prompt) || prompt == "" do
        Map.put(errors, :prompt, "Please select or write a prompt")
      else
        errors
      end

    errors =
      if assigns.project_id == nil do
        Map.put(errors, :project, "Please select a project")
      else
        errors
      end

    errors
  end

  defp non_blank(nil), do: nil
  defp non_blank(""), do: nil
  defp non_blank(str), do: str
end
