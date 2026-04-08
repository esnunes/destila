defmodule DestilaWeb.CraftingBoardLive do
  use DestilaWeb, :live_view

  import DestilaWeb.BoardComponents

  alias Destila.Workflows
  alias Destila.Workflows.Session

  @sections [:waiting_for_user, :processing, :done]
  @section_labels %{
    waiting_for_user: "Waiting for You",
    processing: "Processing",
    done: "Done"
  }

  def mount(_params, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
      Phoenix.PubSub.subscribe(Destila.PubSub, Destila.AI.AlivenessTracker.topic())
    end

    {:ok,
     socket
     |> assign(:current_user, session["current_user"])
     |> assign(:page_title, "Crafting Board")
     |> assign(:alive_sessions, %{})}
  end

  def handle_params(params, _uri, socket) do
    prompts = socket.assigns[:all_prompts] || Destila.Workflows.list_workflow_sessions()
    view_mode = if params["view"] == "workflow", do: :workflow, else: :list
    project_filter = params["project"]

    {:noreply,
     socket
     |> assign(:view_mode, view_mode)
     |> assign(:project_filter, project_filter)
     |> assign(:all_prompts, prompts)
     |> assign_derived_state()
     |> load_alive_sessions()}
  end

  def handle_event("toggle_view", %{"mode" => mode}, socket) do
    new_mode = if mode == "workflow", do: :workflow, else: :list
    {:noreply, push_patch(socket, to: build_path(new_mode, socket.assigns.project_filter))}
  end

  def handle_event("filter_project", %{"project" => ""}, socket) do
    {:noreply, push_patch(socket, to: build_path(socket.assigns.view_mode, nil))}
  end

  def handle_event("filter_project", %{"project" => project_id}, socket) do
    {:noreply, push_patch(socket, to: build_path(socket.assigns.view_mode, project_id))}
  end

  def handle_info({event, _data}, socket)
      when event in [
             :workflow_session_created,
             :workflow_session_updated
           ] do
    prompts = Destila.Workflows.list_workflow_sessions()

    {:noreply,
     socket
     |> assign(:all_prompts, prompts)
     |> assign_derived_state()
     |> load_alive_sessions()}
  end

  def handle_info({:aliveness_changed, ws_id, alive?}, socket) do
    if alive? do
      {:noreply, update(socket, :alive_sessions, &Map.put(&1, ws_id, true))}
    else
      {:noreply, update(socket, :alive_sessions, &Map.delete(&1, ws_id))}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_alive_sessions(socket) do
    if not connected?(socket) do
      socket
    else
      alive_map =
        socket.assigns.all_prompts
        |> Enum.filter(fn session -> Destila.AI.AlivenessTracker.alive?(session.id) end)
        |> Map.new(fn session -> {session.id, true} end)

      assign(socket, :alive_sessions, alive_map)
    end
  end

  # --- Classification ---

  defp classify_prompt(prompt), do: Destila.Workflows.classify(prompt)

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
    case socket.assigns.view_mode do
      :list ->
        sections =
          filtered
          |> Enum.group_by(&classify_prompt/1)
          |> then(fn grouped ->
            Map.new(@sections, fn s -> {s, Map.get(grouped, s, [])} end)
          end)

        assign(socket, :sections, sections)

      :workflow ->
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
                      Enum.filter(wf_prompts, &Session.done?/1)

                    n when is_integer(n) ->
                      Enum.filter(
                        wf_prompts,
                        &(!Session.done?(&1) && &1.current_phase == n)
                      )
                  end

                {phase, name, matching}
              end)

            {wf_type, column_data}
          end)
          |> Enum.reject(fn {_wf_type, column_data} ->
            Enum.all?(column_data, fn {_, _, prompts_in_col} -> prompts_in_col == [] end)
          end)
          |> Enum.sort_by(fn {wf_type, _} ->
            Enum.find_index(Workflows.workflow_types(), &(&1 == wf_type)) || 99
          end)

        assign(socket, :workflow_boards, workflow_boards)
    end
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
    waiting_for_user: "hero-hand-raised-micro",
    processing: "hero-cpu-chip-micro",
    done: "hero-check-circle-micro"
  }

  @section_empty_messages %{
    setup: "No sessions being set up",
    waiting_for_user: "No sessions waiting for you",
    processing: "No sessions being processed",
    done: "No completed sessions yet"
  }

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
        <div class="flex items-center justify-between mb-4">
          <h1 class="text-2xl font-bold tracking-tight">Crafting Board</h1>
          <div class="flex items-center gap-3">
            <.link navigate={~p"/sessions/archived"} class="btn btn-soft btn-sm">
              <.icon name="hero-archive-box-micro" class="size-4" /> Archived
            </.link>
            <.link navigate={~p"/workflows"} class="btn btn-primary btn-sm">
              <.icon name="hero-plus-micro" class="size-4" /> New Session
            </.link>
          </div>
        </div>

        <%!-- View controls --%>
        <div class="flex items-center gap-3 mb-6">
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

          <div id="view-toggle" class="join">
            <button
              phx-click="toggle_view"
              phx-value-mode="list"
              class={[
                "join-item btn btn-sm",
                if(@view_mode == :list, do: "btn-active", else: "")
              ]}
            >
              <.icon name="hero-list-bullet-micro" class="size-4" /> List
            </button>
            <button
              phx-click="toggle_view"
              phx-value-mode="workflow"
              class={[
                "join-item btn btn-sm",
                if(@view_mode == :workflow, do: "btn-active", else: "")
              ]}
            >
              <.icon name="hero-view-columns-micro" class="size-4" /> Workflow
            </button>
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
                  alive?={Map.get(@alive_sessions, card.id, false)}
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
                <.icon name="hero-funnel-micro" class="size-5" /> No sessions match your filter
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
                        alive?={Map.get(@alive_sessions, card.id, false)}
                      />
                      <div
                        :if={col_prompts == []}
                        class="flex items-center justify-center h-16 text-base-content/30 text-sm"
                      >
                        No sessions
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
end
