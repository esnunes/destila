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
    {:ok, assign(socket, opts: assigns.opts, phase_number: assigns.phase_number)}
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

  def handle_event("update_idea", %{"initial_idea" => idea}, socket) do
    errors =
      if idea != "",
        do: Map.delete(socket.assigns.errors, :idea),
        else: socket.assigns.errors

    {:noreply, assign(socket, initial_idea: idea, errors: errors)}
  end

  def handle_event("start_workflow", %{"initial_idea" => idea}, socket) when idea != "" do
    errors =
      if socket.assigns.project_id == nil do
        %{project: "Please select a project"}
      else
        %{}
      end

    if errors == %{} do
      send(
        self(),
        {:phase_complete, socket.assigns.phase_number,
         %{
           action: :session_create,
           project_id: socket.assigns.project_id,
           idea: idea,
           title_generating: true
         }}
      )

      {:noreply, socket}
    else
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
        <.project_selector
          projects={@projects}
          selected_id={@project_id}
          step={@project_step}
          form={@project_form}
          errors={@errors}
          target={@myself}
        />

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
