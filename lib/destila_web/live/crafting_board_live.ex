defmodule DestilaWeb.CraftingBoardLive do
  use DestilaWeb, :live_view

  import DestilaWeb.BoardComponents

  alias Destila.Workflows

  @sections [:setup, :waiting, :in_progress, :done]
  @section_labels %{
    setup: "Setup",
    waiting: "Waiting for Reply",
    in_progress: "In Progress",
    done: "Done"
  }

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
    end

    {:ok,
     socket
     |> assign(:current_user, session["current_user"])
     |> assign(:page_title, "Prompt Crafting")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    prompts = Destila.Prompts.list_prompts(:crafting)
    view_mode = if params["view"] == "workflow", do: :workflow, else: :list
    project_filter = params["project"]

    {:noreply,
     socket
     |> assign(:view_mode, view_mode)
     |> assign(:project_filter, project_filter)
     |> assign(:all_prompts, prompts)
     |> assign_derived_state()}
  end

  @impl true
  def handle_event("toggle_view", _params, socket) do
    new_mode = if socket.assigns.view_mode == :list, do: :workflow, else: :list
    {:noreply, push_patch(socket, to: build_path(new_mode, socket.assigns.project_filter))}
  end

  def handle_event("filter_project", %{"project" => ""}, socket) do
    {:noreply, push_patch(socket, to: build_path(socket.assigns.view_mode, nil))}
  end

  def handle_event("filter_project", %{"project" => project_id}, socket) do
    {:noreply, push_patch(socket, to: build_path(socket.assigns.view_mode, project_id))}
  end

  @impl true
  def handle_info({_event, _data}, socket) do
    prompts = Destila.Prompts.list_prompts(:crafting)

    {:noreply,
     socket
     |> assign(:all_prompts, prompts)
     |> assign_derived_state()}
  end

  # --- Classification ---

  def classify_prompt(prompt) do
    cond do
      prompt.column == :done -> :done
      prompt.phase_status == :setup -> :setup
      prompt.phase_status in [:generating, :conversing, :advance_suggested] -> :waiting
      true -> :in_progress
    end
  end

  # --- Derived State ---

  defp assign_derived_state(socket) do
    prompts = socket.assigns.all_prompts
    project_filter = socket.assigns.project_filter

    filtered =
      if project_filter do
        Enum.filter(prompts, &(&1.project_id == project_filter))
      else
        prompts
      end

    projects =
      prompts
      |> Enum.map(& &1.project)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.name)

    socket
    |> assign(:filtered_prompts, filtered)
    |> assign(:projects, projects)
    |> assign_view_data(filtered)
  end

  defp assign_view_data(socket, filtered) do
    sections =
      filtered
      |> Enum.group_by(&classify_prompt/1)
      |> then(fn grouped ->
        Map.new(@sections, fn s -> {s, Map.get(grouped, s, [])} end)
      end)

    workflow_boards =
      filtered
      |> Enum.group_by(& &1.workflow_type)
      |> Enum.map(fn {wf_type, wf_prompts} ->
        columns = Workflows.phase_columns(wf_type)

        column_data =
          Enum.map(columns, fn {phase, name} ->
            matching =
              case phase do
                :done ->
                  Enum.filter(wf_prompts, &(&1.column == :done))

                n when is_integer(n) ->
                  Enum.filter(wf_prompts, &(&1.column != :done && &1.steps_completed == n))
              end

            {phase, name, matching}
          end)

        {wf_type, column_data}
      end)
      |> Enum.reject(fn {_wf_type, column_data} ->
        Enum.all?(column_data, fn {_, _, prompts_in_col} -> prompts_in_col == [] end)
      end)
      |> Enum.sort_by(fn {wf_type, _} ->
        case wf_type do
          :chore_task -> 0
          :feature_request -> 1
          :project -> 2
        end
      end)

    socket
    |> assign(:sections, sections)
    |> assign(:workflow_boards, workflow_boards)
  end

  # --- URL helpers ---

  defp build_path(view_mode, project_filter) do
    params =
      %{}
      |> then(fn p -> if view_mode == :workflow, do: Map.put(p, "view", "workflow"), else: p end)
      |> then(fn p -> if project_filter, do: Map.put(p, "project", project_filter), else: p end)

    case URI.encode_query(params) do
      "" -> "/crafting"
      qs -> "/crafting?#{qs}"
    end
  end

  # --- Render ---

  @section_icons %{
    setup: "hero-cog-6-tooth-micro",
    waiting: "hero-clock-micro",
    in_progress: "hero-bolt-micro",
    done: "hero-check-circle-micro"
  }

  @section_empty_messages %{
    setup: "No prompts being set up",
    waiting: "No prompts awaiting a reply",
    in_progress: "No prompts in progress",
    done: "No completed prompts yet"
  }

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:section_keys, @sections)
      |> assign(:section_labels, @section_labels)
      |> assign(:section_icons, @section_icons)
      |> assign(:section_empty_messages, @section_empty_messages)

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} page_title={@page_title}>
      <div class="p-6 lg:p-8">
        <%!-- Header --%>
        <div class="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4 mb-6">
          <h1 class="text-2xl font-bold tracking-tight">Crafting Board</h1>

          <div class="flex items-center gap-3">
            <%!-- Project filter --%>
            <form phx-change="filter_project" id="project-filter-form">
              <select
                name="project"
                id="project-filter"
                class="select select-sm select-bordered"
              >
                <option value="">All projects</option>
                <option
                  :for={project <- @projects}
                  value={project.id}
                  selected={@project_filter == project.id}
                >
                  {project.name}
                </option>
              </select>
            </form>

            <%!-- View toggle --%>
            <button
              id="view-toggle"
              phx-click="toggle_view"
              class={[
                "btn btn-sm gap-1",
                if(@view_mode == :workflow, do: "btn-primary", else: "btn-ghost")
              ]}
            >
              <.icon name="hero-view-columns-micro" class="size-4" /> Group by Workflow
            </button>

            <%!-- New Prompt --%>
            <.link navigate={~p"/prompts/new?from=/crafting"} class="btn btn-primary btn-sm">
              <.icon name="hero-plus-micro" class="size-4" /> New Prompt
            </.link>
          </div>
        </div>

        <%!-- List View --%>
        <%= if @view_mode == :list do %>
          <div id="crafting-sections" class="space-y-6">
            <div :for={section <- @section_keys} id={"section-#{section}"}>
              <div class="flex items-center gap-2 mb-3 px-1">
                <h3 class="text-xs font-medium text-base-content/50 uppercase">
                  {@section_labels[section]}
                </h3>
                <span class="badge badge-sm badge-ghost">
                  {length(@sections[section])}
                </span>
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-3">
                <.crafting_card
                  :for={card <- @sections[section]}
                  card={card}
                  project_filter={@project_filter}
                />
              </div>

              <div
                :if={@sections[section] == []}
                class="flex items-center justify-center gap-2 h-16 text-base-content/20 text-sm bg-base-200/20 rounded-xl border border-dashed border-base-300/50"
              >
                <.icon name={@section_icons[section]} class="size-4" />
                {@section_empty_messages[section]}
              </div>
            </div>
          </div>

          <%!-- Workflow View --%>
        <% else %>
          <div id="crafting-workflow-boards" class="space-y-8">
            <%= if @workflow_boards == [] do %>
              <div class="flex flex-col items-center justify-center h-32 gap-2 text-base-content/20 text-sm bg-base-200/20 rounded-xl border border-dashed border-base-300/50">
                <.icon name="hero-funnel-micro" class="size-5" /> No prompts match your filter
              </div>
            <% else %>
              <div
                :for={{wf_type, column_data} <- @workflow_boards}
                id={"workflow-board-#{wf_type}"}
                class="space-y-3"
              >
                <div class="flex items-center gap-2 px-1">
                  <.workflow_badge type={wf_type} />
                  <h3 class="text-sm font-semibold">{workflow_label(wf_type)}</h3>
                </div>

                <div class="flex gap-4 overflow-x-auto pb-4">
                  <div
                    :for={{_phase, name, col_prompts} <- column_data}
                    class="flex flex-col min-w-[240px] max-w-[280px] w-full"
                  >
                    <div class="flex items-center gap-2 mb-2 px-1">
                      <h4 class="text-xs font-medium text-base-content/50 uppercase">{name}</h4>
                      <span class="badge badge-sm badge-ghost">{length(col_prompts)}</span>
                    </div>
                    <div class="flex flex-col gap-2 min-h-[120px] p-2 bg-base-200/50 rounded-xl">
                      <.crafting_card
                        :for={card <- col_prompts}
                        card={card}
                        project_filter={@project_filter}
                        compact
                      />
                      <div
                        :if={col_prompts == []}
                        class="flex items-center justify-center h-16 text-base-content/30 text-sm"
                      >
                        No prompts
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp workflow_label(:feature_request), do: "Feature Request"
  defp workflow_label(:project), do: "Project"
  defp workflow_label(:chore_task), do: "Chore/Task"
end
