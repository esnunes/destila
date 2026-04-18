defmodule DestilaWeb.DraftFormLive do
  @moduledoc """
  LiveView for creating and editing drafts.

  - `/drafts/new` — create a new draft
  - `/drafts/:id` — edit/detail view for an existing draft (also the launch
    entry point and the discard action)
  """

  use DestilaWeb, :live_view

  import DestilaWeb.ProjectComponents

  alias Destila.Drafts

  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")

    case Drafts.get_draft(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Draft not found")
         |> push_navigate(to: ~p"/drafts")}

      draft ->
        {:ok, assign_form(socket, :edit, draft)}
    end
  end

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
    {:ok, assign_form(socket, :new, nil)}
  end

  defp assign_form(socket, mode, draft) do
    params =
      case draft do
        nil ->
          %{"prompt" => "", "priority" => "", "project_id" => ""}

        %Drafts.Draft{} = d ->
          %{
            "prompt" => d.prompt || "",
            "priority" => if(d.priority, do: Atom.to_string(d.priority), else: ""),
            "project_id" => d.project_id || ""
          }
      end

    page_title = if mode == :edit, do: "Edit Draft", else: "New Draft"

    socket
    |> assign(:mode, mode)
    |> assign(:draft, draft)
    |> assign(:page_title, page_title)
    |> assign(:projects, Destila.Projects.list_projects())
    |> assign(:project_id, params["project_id"])
    |> assign(:project_step, :select)
    |> assign(:prompt, params["prompt"])
    |> assign(:priority, params["priority"])
    |> assign(:errors, %{})
  end

  # --- Form events ---

  def handle_event("validate", params, socket) do
    {:noreply,
     socket
     |> assign(:prompt, params["prompt"] || "")
     |> assign(:priority, params["priority"] || "")}
  end

  def handle_event("save", params, socket) do
    socket =
      socket
      |> assign(:prompt, params["prompt"] || socket.assigns.prompt)
      |> assign(:priority, params["priority"] || socket.assigns.priority)

    attrs = %{
      prompt: String.trim(socket.assigns.prompt || ""),
      priority: socket.assigns.priority,
      project_id: socket.assigns.project_id
    }

    errors = validate(attrs)

    cond do
      errors != %{} ->
        {:noreply, assign(socket, :errors, errors)}

      socket.assigns.mode == :edit ->
        handle_save_result(Drafts.update_draft(socket.assigns.draft, attrs), socket)

      true ->
        handle_save_result(Drafts.create_draft(attrs), socket)
    end
  end

  # --- Detail-only events ---

  def handle_event("discard", _params, %{assigns: %{mode: :edit, draft: draft}} = socket) do
    {:ok, _} = Drafts.archive_draft(draft)

    {:noreply,
     socket
     |> put_flash(:info, "Draft discarded")
     |> push_navigate(to: ~p"/drafts")}
  end

  def handle_event("start_workflow", _params, %{assigns: %{mode: :edit, draft: draft}} = socket) do
    {:noreply, push_navigate(socket, to: ~p"/workflows?draft_id=#{draft.id}")}
  end

  # --- Project selector events ---

  def handle_event("select_project", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:project_id, id)
     |> assign(:errors, Map.delete(socket.assigns.errors, :project))}
  end

  def handle_event("show_create_project", _params, socket) do
    {:noreply, assign(socket, project_step: :create, errors: %{})}
  end

  def handle_event("back_to_select", _params, socket) do
    {:noreply, assign(socket, :project_step, :select)}
  end

  defp handle_save_result({:ok, _draft}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/drafts")}
  end

  defp handle_save_result({:error, changeset}, socket) do
    {:noreply, assign(socket, :errors, changeset_to_errors(changeset))}
  end

  # --- Callbacks ---

  def handle_info({:project_saved, project}, socket) do
    {:noreply,
     socket
     |> assign(:project_id, project.id)
     |> assign(:projects, Destila.Projects.list_projects())
     |> assign(:project_step, :select)
     |> assign(:errors, %{})}
  end

  def handle_info({event, _data}, socket)
      when event in [:project_created, :project_updated, :project_deleted] do
    {:noreply, assign(socket, :projects, Destila.Projects.list_projects())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp validate(attrs) do
    errors = %{}

    errors =
      if attrs.prompt == "",
        do: Map.put(errors, :prompt, "Please write a prompt"),
        else: errors

    errors =
      if attrs.priority in ["low", "medium", "high"],
        do: errors,
        else: Map.put(errors, :priority, "Please pick a priority")

    errors =
      if attrs.project_id in [nil, ""],
        do: Map.put(errors, :project, "Please select a project"),
        else: errors

    errors
  end

  defp changeset_to_errors(%Ecto.Changeset{} = changeset) do
    Enum.reduce(changeset.errors, %{}, fn
      {:prompt, {msg, _}}, acc -> Map.put(acc, :prompt, msg)
      {:priority, {msg, _}}, acc -> Map.put(acc, :priority, msg)
      {:project_id, {msg, _}}, acc -> Map.put(acc, :project, msg)
      _, acc -> acc
    end)
  end

  # --- Render ---

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title}>
      <div class="overflow-y-auto h-screen px-6 py-6">
        <div class="max-w-2xl mx-auto space-y-6">
          <div class="flex justify-between items-center">
            <h1 class="text-2xl font-bold tracking-tight">{@page_title}</h1>
            <.link
              navigate={~p"/drafts"}
              class="text-xs text-base-content/40 hover:text-base-content/60 flex items-center gap-1"
              id="back-to-drafts"
            >
              <.icon name="hero-arrow-left-micro" class="size-3.5" /> Back to drafts
            </.link>
          </div>

          <form
            id="draft-form"
            phx-submit="save"
            phx-change="validate"
            class="space-y-5"
          >
            <%!-- Prompt --%>
            <div>
              <label class="block text-sm font-medium mb-2" for="draft-prompt">
                Prompt <span class="text-error">*</span>
              </label>
              <textarea
                id="draft-prompt"
                name="prompt"
                rows="6"
                phx-debounce="300"
                placeholder="What's the idea?"
                aria-invalid={@errors[:prompt] && "true"}
                class={[
                  "textarea textarea-bordered w-full",
                  @errors[:prompt] && "textarea-error"
                ]}
              >{@prompt}</textarea>
              <p :if={@errors[:prompt]} class="text-xs text-error mt-1">{@errors[:prompt]}</p>
            </div>

            <%!-- Priority --%>
            <div>
              <label class="block text-sm font-medium mb-2" for="draft-priority">
                Priority <span class="text-error">*</span>
              </label>
              <select
                id="draft-priority"
                name="priority"
                aria-invalid={@errors[:priority] && "true"}
                class={[
                  "select select-bordered w-full",
                  @errors[:priority] && "select-error"
                ]}
              >
                <option value="" disabled selected={@priority in [nil, ""]}>
                  Select priority…
                </option>
                <option value="high" selected={@priority == "high"}>High</option>
                <option value="medium" selected={@priority == "medium"}>Medium</option>
                <option value="low" selected={@priority == "low"}>Low</option>
              </select>
              <p :if={@errors[:priority]} class="text-xs text-error mt-1">{@errors[:priority]}</p>
            </div>
          </form>

          <%!-- Project section (its own <.live_component> form) --%>
          <div class="border-t border-base-300 pt-6">
            <.project_selector
              projects={@projects}
              selected_id={@project_id}
              step={@project_step}
              errors={@errors}
              target={nil}
            />
            <%= if @mode == :edit && @draft.project && @draft.project.archived_at do %>
              <p class="text-xs text-warning mt-2" id="archived-project-indicator">
                <.icon name="hero-archive-box-micro" class="size-3.5 inline" />
                The linked project is archived. Select another project or keep this one.
              </p>
            <% end %>
          </div>

          <%!-- Actions --%>
          <div :if={@project_step == :select} class="flex flex-col gap-2">
            <button
              type="submit"
              form="draft-form"
              class="btn btn-primary w-full"
              id="save-draft-btn"
            >
              <.icon name="hero-check-micro" class="size-4" /> Save draft
            </button>

            <%= if @mode == :edit do %>
              <button
                phx-click="start_workflow"
                class="btn btn-secondary w-full"
                id="start-workflow-btn"
              >
                <.icon name="hero-bolt-micro" class="size-4" /> Start workflow
              </button>

              <button
                phx-click="discard"
                data-confirm="Discard this draft? This cannot be undone."
                class="btn btn-ghost btn-sm text-error/70 hover:text-error"
                id="discard-draft-btn"
              >
                Discard
              </button>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
