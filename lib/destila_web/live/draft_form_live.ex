defmodule DestilaWeb.DraftFormLive do
  @moduledoc """
  LiveView for creating and editing drafts.

  - `/drafts/new` — create a new draft
  - `/drafts/:id` — edit/detail view for an existing draft (also the launch
    entry point and the discard action)
  """

  use DestilaWeb, :live_view

  import DestilaWeb.ProjectComponents
  import Ecto.Changeset

  alias Destila.Drafts
  alias Destila.Drafts.Draft

  @priority_options [{"High", "high"}, {"Medium", "medium"}, {"Low", "low"}]

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
    draft_struct = draft || %Draft{}

    params = %{
      "prompt" => draft_struct.prompt || "",
      "priority" => priority_to_string(draft_struct.priority)
    }

    socket
    |> assign(:mode, mode)
    |> assign(:draft, draft)
    |> assign(:page_title, if(mode == :edit, do: "Edit Draft", else: "New Draft"))
    |> assign(:projects, Destila.Projects.list_projects())
    |> assign(:project_id, draft_struct.project_id)
    |> assign(:project_step, :select)
    |> assign(:project_error, nil)
    |> assign(:priority_options, @priority_options)
    |> assign(:form, to_form(params, as: :draft))
  end

  # --- Form events ---

  def handle_event("validate", %{"draft" => params}, socket) do
    changeset =
      form_changeset(
        socket.assigns.draft || %Draft{},
        Map.put(params, "project_id", socket.assigns.project_id)
      )

    {:noreply,
     assign(
       socket,
       :form,
       to_form(params, as: :draft, errors: field_errors(changeset), action: :validate)
     )}
  end

  def handle_event("save", params, socket) do
    action = params["action"] || "save"
    form_params = Map.get(params, "draft", %{})

    attrs = %{
      prompt: String.trim(form_params["prompt"] || ""),
      priority: form_params["priority"],
      project_id: socket.assigns.project_id
    }

    changeset =
      form_changeset(socket.assigns.draft || %Draft{}, %{
        "prompt" => attrs.prompt,
        "priority" => attrs.priority,
        "project_id" => attrs.project_id
      })

    if changeset.valid? do
      result =
        case socket.assigns.mode do
          :edit -> Drafts.update_draft(socket.assigns.draft, attrs)
          :new -> Drafts.create_draft(attrs)
        end

      handle_save_result(result, action, socket)
    else
      {:noreply,
       socket
       |> assign(
         :form,
         to_form(form_params, as: :draft, errors: field_errors(changeset), action: :validate)
       )
       |> assign(:project_error, project_error_from(changeset))}
    end
  end

  # --- Detail-only events ---

  def handle_event("discard", _params, %{assigns: %{mode: :edit, draft: draft}} = socket) do
    case Drafts.archive_draft(draft) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Draft discarded")
         |> push_navigate(to: ~p"/drafts")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not discard draft")}
    end
  end

  # --- Project selector events ---

  def handle_event("select_project", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:project_id, id)
     |> assign(:project_error, nil)}
  end

  def handle_event("show_create_project", _params, socket) do
    {:noreply, assign(socket, project_step: :create, project_error: nil)}
  end

  def handle_event("back_to_select", _params, socket) do
    {:noreply, assign(socket, :project_step, :select)}
  end

  defp handle_save_result({:ok, draft}, "start_workflow", socket) do
    {:noreply, push_navigate(socket, to: ~p"/workflows?draft_id=#{draft.id}")}
  end

  defp handle_save_result({:ok, _draft}, _action, socket) do
    {:noreply, push_navigate(socket, to: ~p"/drafts")}
  end

  defp handle_save_result({:error, %Ecto.Changeset{} = changeset}, _action, socket) do
    form_params =
      socket.assigns.form.params
      |> Map.put("prompt", Ecto.Changeset.get_field(changeset, :prompt) || "")
      |> Map.put(
        "priority",
        Ecto.Changeset.get_field(changeset, :priority) |> priority_to_string()
      )

    {:noreply,
     socket
     |> assign(
       :form,
       to_form(form_params, as: :draft, errors: field_errors(changeset), action: :validate)
     )
     |> assign(:project_error, project_error_from(changeset))}
  end

  # --- Callbacks ---

  def handle_info({:project_saved, project}, socket) do
    {:noreply,
     socket
     |> assign(:project_id, project.id)
     |> assign(:projects, Destila.Projects.list_projects())
     |> assign(:project_step, :select)
     |> assign(:project_error, nil)}
  end

  def handle_info({event, _data}, socket)
      when event in [:project_created, :project_updated, :project_deleted] do
    {:noreply, assign(socket, :projects, Destila.Projects.list_projects())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp form_changeset(draft, params) do
    params = normalize_priority(params)

    draft
    |> cast(params, [:prompt, :priority, :project_id])
    |> validate_required([:prompt], message: "Please write a prompt")
    |> validate_required([:priority], message: "Please pick a priority")
    |> validate_required([:project_id], message: "Please select a project")
  end

  defp normalize_priority(%{"priority" => ""} = params), do: Map.put(params, "priority", nil)
  defp normalize_priority(params), do: params

  defp field_errors(%Ecto.Changeset{errors: errors}) do
    Enum.filter(errors, fn {field, _} -> field in [:prompt, :priority] end)
  end

  defp project_error_from(%Ecto.Changeset{errors: errors}) do
    case Keyword.get(errors, :project_id) do
      {msg, _opts} -> msg
      nil -> nil
    end
  end

  defp priority_to_string(nil), do: ""
  defp priority_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp priority_to_string(str) when is_binary(str), do: str

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

          <.form
            for={@form}
            id="draft-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-5"
          >
            <.input
              field={@form[:prompt]}
              type="textarea"
              label="Prompt *"
              rows="6"
              placeholder="What's the idea?"
              phx-debounce="300"
            />

            <.input
              field={@form[:priority]}
              type="select"
              label="Priority *"
              prompt="Select priority…"
              options={@priority_options}
            />
          </.form>

          <%!-- Project section (its own <.live_component> form) --%>
          <div class="border-t border-base-300 pt-6">
            <.project_selector
              projects={@projects}
              selected_id={@project_id}
              step={@project_step}
              errors={%{project: @project_error}}
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
              name="action"
              value="save"
              class="btn btn-primary w-full"
              id="save-draft-btn"
            >
              <.icon name="hero-check-micro" class="size-4" /> Save draft
            </button>

            <%= if @mode == :edit do %>
              <button
                type="submit"
                form="draft-form"
                name="action"
                value="start_workflow"
                class="btn btn-secondary w-full"
                id="start-workflow-btn"
              >
                <.icon name="hero-bolt-micro" class="size-4" /> Start workflow
              </button>

              <button
                type="button"
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
