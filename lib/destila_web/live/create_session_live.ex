defmodule DestilaWeb.CreateSessionLive do
  @moduledoc """
  LiveView for workflow session creation. Handles:
  - `/workflows` — workflow type selection
  - `/workflows/:workflow_type` — adaptive creation form driven by `creation_config/0`
  """

  use DestilaWeb, :live_view

  alias Destila.Workflows

  def mount(params, session, socket) do
    socket = assign(socket, :current_user, session["current_user"])

    if Map.has_key?(params, "workflow_type") do
      mount_form(params["workflow_type"], socket)
    else
      mount_type_selection(socket)
    end
  end

  defp mount_type_selection(socket) do
    {:ok,
     socket
     |> assign(:view, :selecting_type)
     |> assign(:workflow_metadata, Workflows.workflow_type_metadata())
     |> assign(:page_title, "New Session")}
  end

  defp mount_form(workflow_type_str, socket) do
    workflow_type = String.to_existing_atom(workflow_type_str)
    source_sessions = Workflows.list_source_sessions(workflow_type)

    {:ok,
     socket
     |> assign(:view, :form)
     |> assign(:workflow_type, workflow_type)
     |> assign(:input_label, Workflows.creation_label(workflow_type))
     |> assign(:source_sessions, source_sessions)
     |> assign(:selected_session_id, nil)
     |> assign(:selected_text, nil)
     |> assign(:input_text, "")
     |> assign(:input_mode, if(source_sessions != [], do: :select, else: :manual))
     |> assign(:projects, Destila.Projects.list_projects())
     |> assign(:project_id, nil)
     |> assign(:project_step, :select)
     |> assign(
       :project_form,
       to_form(%{"name" => "", "git_repo_url" => "", "local_folder" => ""})
     )
     |> assign(:errors, %{})
     |> assign(:page_title, Workflows.default_title(workflow_type))}
  end

  # --- Source session events ---

  def handle_event("select_session", %{"id" => session_id}, socket) do
    case Enum.find(socket.assigns.source_sessions, fn {ws, _} -> ws.id == session_id end) do
      nil ->
        {:noreply, socket}

      {ws, text} ->
        project_id = if ws.project_id, do: ws.project_id, else: socket.assigns.project_id

        {:noreply,
         socket
         |> assign(:selected_session_id, session_id)
         |> assign(:selected_text, text)
         |> assign(:input_text, text)
         |> assign(:project_id, project_id)
         |> assign(:input_mode, :select)
         |> assign(:errors, Map.delete(socket.assigns.errors, :input))}
    end
  end

  def handle_event("switch_to_manual", _params, socket) do
    {:noreply,
     socket
     |> assign(:input_mode, :manual)
     |> assign(:selected_session_id, nil)
     |> assign(:selected_text, nil)
     |> assign(:input_text, "")}
  end

  def handle_event("switch_to_select", _params, socket) do
    {:noreply, assign(socket, :input_mode, :select)}
  end

  def handle_event("update_text", %{"input_text" => text}, socket) do
    errors =
      if text != "",
        do: Map.delete(socket.assigns.errors, :input),
        else: socket.assigns.errors

    {:noreply, assign(socket, input_text: text, errors: errors)}
  end

  # --- Project selection events ---

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

  def handle_event("start_workflow", params, socket) do
    # Update input_text from form params if present (form submit sends params)
    socket =
      case params do
        %{"input_text" => text} when text != "" -> assign(socket, :input_text, text)
        _ -> socket
      end

    errors = validate(socket.assigns)

    if errors == %{} do
      %{
        workflow_type: workflow_type,
        input_text: input_text,
        selected_session_id: selected_session_id,
        project_id: project_id
      } = socket.assigns

      {:ok, ws} =
        Workflows.create_workflow_session(%{
          workflow_type: workflow_type,
          input_text: input_text,
          selected_session_id: selected_session_id,
          project_id: project_id
        })

      {:noreply, push_navigate(socket, to: ~p"/sessions/#{ws.id}")}
    else
      {:noreply, assign(socket, :errors, errors)}
    end
  end

  # --- Render: type selection ---

  def render(%{view: :selecting_type} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="flex items-center justify-center min-h-screen">
        <div class="w-full max-w-lg px-6">
          <div class="text-center mb-8">
            <h2 class="text-xl font-bold">What are you creating?</h2>
            <p class="text-sm text-base-content/50 mt-1">Choose a workflow type to get started</p>
          </div>

          <div class="grid gap-4">
            <.link
              :for={wf <- @workflow_metadata}
              navigate={~p"/workflows/#{wf.type}"}
              class="card bg-base-100 border-2 border-base-300 hover:border-primary transition-colors cursor-pointer text-left"
              id={"type-#{wf.type}"}
            >
              <div class="card-body p-5">
                <.icon name={wf.icon} class={["size-8 mb-2", wf.icon_class]} />
                <h3 class="font-semibold">{wf.label}</h3>
                <p class="text-xs text-base-content/50">{wf.description}</p>
              </div>
            </.link>
          </div>

          <.link
            navigate={~p"/crafting"}
            class="btn btn-ghost btn-sm w-full mt-6 text-base-content/40"
          >
            &larr; Back to crafting board
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Render: creation form ---

  def render(%{view: :form} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} page_title={@page_title}>
      <div class="overflow-y-auto h-screen px-6 py-6">
        <div class="max-w-2xl mx-auto space-y-6">
          <div class="flex justify-end">
            <.link
              navigate={~p"/workflows"}
              class="text-xs text-base-content/40 hover:text-base-content/60 transition-colors flex items-center gap-1"
            >
              <.icon name="hero-arrow-left-micro" class="size-3.5" /> Back to workflow selection
            </.link>
          </div>

          <%!-- Input section --%>
          <div>
            <div class="mb-4">
              <h2 class="text-lg font-bold">{input_heading(@input_label, @source_sessions)}</h2>
              <p class="text-sm text-base-content/50 mt-1">
                {input_description(@input_label, @source_sessions)}
              </p>
            </div>

            <%!-- Mode tabs (only when source sessions exist) --%>
            <div :if={@source_sessions != []} class="flex gap-2 mb-4">
              <button
                phx-click="switch_to_select"
                class={[
                  "btn btn-sm",
                  if(@input_mode == :select, do: "btn-primary", else: "btn-ghost")
                ]}
                id="tab-select-source"
              >
                Select existing
              </button>
              <button
                phx-click="switch_to_manual"
                class={[
                  "btn btn-sm",
                  if(@input_mode == :manual, do: "btn-primary", else: "btn-ghost")
                ]}
                id="tab-manual-input"
              >
                Write manually
              </button>
            </div>

            <%!-- Select from existing sessions --%>
            <div :if={@input_mode == :select && @source_sessions != []}>
              <div class="space-y-2 max-h-64 overflow-y-auto" id="session-source-list">
                <button
                  :for={{ws, text} <- @source_sessions}
                  phx-click="select_session"
                  phx-value-id={ws.id}
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
                    {String.slice(text, 0, 200)}
                  </div>
                </button>
              </div>
            </div>

            <%!-- Manual text input --%>
            <div :if={@input_mode == :manual || @source_sessions == []}>
              <form
                id="manual-input-form"
                phx-change="update_text"
                phx-submit="start_workflow"
              >
                <textarea
                  id="input_text"
                  name="input_text"
                  rows={if(@source_sessions == [], do: 5, else: 8)}
                  placeholder={input_placeholder(@input_label)}
                  aria-invalid={@errors[:input] && "true"}
                  class={[
                    "textarea textarea-bordered w-full",
                    @errors[:input] && "textarea-error"
                  ]}
                  phx-debounce="300"
                >{@input_text}</textarea>
              </form>
            </div>

            <p :if={@errors[:input]} class="text-xs text-error mt-2">
              {@errors[:input]}
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
              target={nil}
            />
          </div>

          <%!-- Start button --%>
          <div :if={@project_step == :select}>
            <button
              phx-click="start_workflow"
              class="btn btn-primary w-full"
              id="start-workflow-btn"
            >
              <.icon name="hero-arrow-right-micro" class="size-4" /> Start
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Private helpers ---

  defp validate(assigns) do
    errors = %{}

    input_text = String.trim(assigns.input_text || "")

    errors =
      cond do
        assigns.input_mode == :select && assigns.selected_session_id != nil ->
          errors

        input_text == "" ->
          label = String.downcase(assigns.input_label)
          article = if String.starts_with?(label, ~w(a e i o u)), do: "an", else: "a"
          Map.put(errors, :input, "Please select or write #{article} #{label}")

        true ->
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

  defp input_heading(label, source_sessions) do
    if source_sessions != [] do
      "Choose a #{String.downcase(label)}"
    else
      "Describe your #{String.downcase(label)}"
    end
  end

  defp input_description(label, source_sessions) do
    if source_sessions != [] do
      "Select from a completed session or write your own"
    else
      "What #{String.downcase(label)} do you want to work on?"
    end
  end

  defp input_placeholder(label) do
    "Describe your #{String.downcase(label)} in as much detail as you'd like..."
  end
end
