defmodule DestilaWeb.AgentSessionCreateLive do
  @moduledoc """
  Form-based entry point for creating a new MCP-driven agent session.

  Lets the user pick a workflow (from YAML registry), a host mode, and
  optionally an associated project. On submit redirects to
  `/agent-sessions/:id`.
  """

  use DestilaWeb, :live_view

  alias Destila.Agent.{Sessions, WorkflowLoader}

  @impl true
  def mount(_params, _session, socket) do
    workflows = WorkflowLoader.list_all()
    projects = Destila.Projects.list_projects()

    form =
      to_form(%{
        "workflow_name" => default_workflow(workflows),
        "host_mode" => "embedded",
        "project_id" => ""
      })

    {:ok,
     socket
     |> assign(:page_title, "New Agent Session")
     |> assign(:workflows, workflows)
     |> assign(:projects, projects)
     |> assign(:form, form)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("validate", %{"agent_session" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :agent_session))}
  end

  def handle_event("create", %{"agent_session" => params}, socket) do
    workflow_name = Map.get(params, "workflow_name", "")
    host_mode = Map.get(params, "host_mode", "embedded")
    project_id = empty_to_nil(Map.get(params, "project_id"))

    with {:ok, workflow} <- WorkflowLoader.get(workflow_name) do
      attrs = %{
        workflow_name: workflow.name,
        host_mode: host_mode,
        project_id: project_id,
        total_phases: length(workflow.phases),
        current_phase_index: 0
      }

      case Sessions.create_session(attrs) do
        {:ok, session} ->
          {:noreply, push_navigate(socket, to: ~p"/agent-sessions/#{session.id}")}

        {:error, changeset} ->
          {:noreply,
           assign(socket, :error, "Could not create session: #{inspect(changeset.errors)}")}
      end
    else
      {:error, :not_found} ->
        {:noreply, assign(socket, :error, "Please choose a workflow")}
    end
  end

  defp default_workflow([]), do: ""
  defp default_workflow([wf | _]), do: wf.name

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(nil), do: nil
  defp empty_to_nil(v), do: v

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title}>
      <div class="p-6 lg:p-8 max-w-2xl">
        <h1 class="text-2xl font-bold mb-4">New agent-driven session</h1>

        <p class="text-sm text-base-content/60 mb-6">
          MCP-driven sessions let an external Claude Code agent talk to Destila
          via tool calls. No chat textarea — interact directly with the agent.
        </p>

        <div :if={@error} class="alert alert-error mb-4">
          {@error}
        </div>

        <.form
          for={@form}
          id="agent-session-form"
          phx-change="validate"
          phx-submit="create"
          as={:agent_session}
          class="space-y-4"
        >
          <div>
            <label class="label" for="agent_session_workflow_name">
              <span class="label-text">Workflow</span>
            </label>
            <select
              id="agent_session_workflow_name"
              name="agent_session[workflow_name]"
              class="select select-bordered w-full"
            >
              <option value="" disabled selected={@form[:workflow_name].value in [nil, ""]}>
                Choose a workflow
              </option>
              <option
                :for={wf <- @workflows}
                value={wf.name}
                selected={@form[:workflow_name].value == wf.name}
              >
                {wf.name}
              </option>
            </select>
          </div>

          <div>
            <span class="label-text">Host mode</span>
            <div class="flex gap-4 mt-1">
              <label class="cursor-pointer flex items-center gap-2">
                <input
                  type="radio"
                  name="agent_session[host_mode]"
                  value="embedded"
                  class="radio radio-sm"
                  checked={@form[:host_mode].value in ["embedded", nil]}
                />
                <span>Embedded terminal</span>
              </label>
              <label class="cursor-pointer flex items-center gap-2">
                <input
                  type="radio"
                  name="agent_session[host_mode]"
                  value="external"
                  class="radio radio-sm"
                  checked={@form[:host_mode].value == "external"}
                />
                <span>External CLI</span>
              </label>
            </div>
          </div>

          <div>
            <label class="label" for="agent_session_project_id">
              <span class="label-text">Project (optional)</span>
            </label>
            <select
              id="agent_session_project_id"
              name="agent_session[project_id]"
              class="select select-bordered w-full"
            >
              <option value="">No project</option>
              <option
                :for={project <- @projects}
                value={project.id}
                selected={@form[:project_id].value == project.id}
              >
                {project.name}
              </option>
            </select>
          </div>

          <div class="pt-4">
            <button type="submit" id="create-agent-session" class="btn btn-primary">
              Create session
            </button>
            <.link navigate={~p"/crafting"} class="btn btn-ghost">
              Cancel
            </.link>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
