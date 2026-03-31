defmodule DestilaWeb.WorkflowRunnerLive do
  @moduledoc """
  Generic workflow runner LiveView. Orchestrates phase transitions by mounting
  each phase's LiveComponent. Does not contain any workflow-specific logic.

  Three mount paths:
  - `/workflows` — workflow type selection
  - `/workflows/:workflow_type` — pre-session (Phase 1, in-memory)
  - `/sessions/:id` — post-session (Phase 2+, DB-driven)
  """

  use DestilaWeb, :live_view

  import DestilaWeb.BoardComponents, only: [workflow_badge: 1, progress_indicator: 1]

  alias Destila.Workflows.Session

  alias Destila.Workflows

  def mount(params, session, socket) do
    socket = assign(socket, :current_user, session["current_user"])

    cond do
      Map.has_key?(params, "id") ->
        mount_session(params["id"], socket)

      Map.has_key?(params, "workflow_type") ->
        mount_workflow(params["workflow_type"], socket)

      true ->
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

  defp mount_workflow(workflow_type_str, socket) do
    workflow_type = String.to_existing_atom(workflow_type_str)
    phases = Workflows.phases(workflow_type)

    {:ok,
     socket
     |> assign(:view, :running)
     |> assign(:workflow_type, workflow_type)
     |> assign(:workflow_session, nil)
     |> assign(:project, nil)
     |> assign(:phases, phases)
     |> assign(:current_phase, 1)
     |> assign(:total_phases, length(phases))
     |> assign(:editing_title, false)
     |> assign(:metadata, %{})
     |> assign(:page_title, Workflows.default_title(workflow_type))
     |> assign(:streaming_chunks, nil)}
  end

  defp mount_session(id, socket) do
    workflow_session = Workflows.get_workflow_session(id)

    if workflow_session do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
        Phoenix.PubSub.subscribe(Destila.PubSub, Destila.PubSubHelper.ai_stream_topic(id))
      end

      workflow_type = workflow_session.workflow_type
      phases = Workflows.phases(workflow_type)

      project =
        if workflow_session.project_id,
          do: Destila.Projects.get_project(workflow_session.project_id)

      {:ok,
       socket
       |> assign(:view, :running)
       |> assign(:workflow_type, workflow_type)
       |> assign(:workflow_session, workflow_session)
       |> assign(:project, project)
       |> assign(:phases, phases)
       |> assign(:current_phase, workflow_session.current_phase)
       |> assign(:total_phases, workflow_session.total_phases)
       |> assign(:editing_title, false)
       |> assign(:metadata, Workflows.get_metadata(workflow_session.id))
       |> assign(:page_title, workflow_session.title)
       |> assign(:streaming_chunks, nil)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Session not found")
       |> push_navigate(to: ~p"/crafting")}
    end
  end

  # --- Session management events ---

  def handle_event("edit_title", _params, socket) do
    {:noreply, assign(socket, :editing_title, true)}
  end

  def handle_event("save_title", %{"title" => title}, socket) do
    ws = socket.assigns.workflow_session
    title = String.trim(title)
    title = if title == "", do: ws.title, else: title
    {:ok, ws} = Workflows.update_workflow_session(ws, %{title: title})

    {:noreply,
     socket
     |> assign(:workflow_session, ws)
     |> assign(:editing_title, false)
     |> assign(:page_title, ws.title)}
  end

  def handle_event("archive_session", _params, socket) do
    {:ok, _ws} = Workflows.archive_workflow_session(socket.assigns.workflow_session)

    {:noreply,
     socket
     |> put_flash(:info, "Session archived")
     |> push_navigate(to: ~p"/crafting")}
  end

  def handle_event("unarchive_session", _params, socket) do
    {:ok, ws} = Workflows.unarchive_workflow_session(socket.assigns.workflow_session)

    {:noreply,
     socket
     |> assign(:workflow_session, ws)
     |> put_flash(:info, "Session restored")}
  end

  def handle_event("confirm_advance", _params, socket) do
    ws = socket.assigns.workflow_session
    next_phase = ws.current_phase + 1

    if next_phase > ws.total_phases do
      {:noreply, socket}
    else
      Destila.Executions.Engine.advance_to_next(ws)
      ws = Workflows.get_workflow_session!(ws.id)

      {:noreply,
       socket
       |> assign(:workflow_session, ws)
       |> assign(:current_phase, ws.current_phase)
       |> assign(:page_title, ws.title)}
    end
  end

  def handle_event("decline_advance", _params, socket) do
    ws = socket.assigns.workflow_session

    case Destila.Executions.get_current_phase_execution(ws.id) do
      %{status: "awaiting_confirmation"} = pe -> Destila.Executions.reject_completion(pe)
      _ -> :ok
    end

    {:ok, ws} = Workflows.update_workflow_session(ws, %{phase_status: :conversing})
    {:noreply, assign(socket, :workflow_session, ws)}
  end

  def handle_event("mark_done", _params, socket) do
    ws = socket.assigns.workflow_session
    ai_session = Destila.AI.get_ai_session_for_workflow(ws.id)

    if ai_session do
      Destila.AI.create_message(ai_session.id, %{
        role: :system,
        content: Workflows.completion_message(ws.workflow_type),
        phase: ws.current_phase
      })
    end

    {:ok, ws} =
      Workflows.update_workflow_session(ws, %{
        done_at: DateTime.utc_now(),
        phase_status: nil
      })

    {:noreply, assign(socket, :workflow_session, ws)}
  end

  # --- Phase signals from LiveComponents ---

  # Phase complete with session creation request
  def handle_info({:phase_complete, phase, %{action: :session_create} = data}, socket) do
    workflow_type = socket.assigns.workflow_type

    # If a source session was selected, reuse its title
    title =
      if data[:selected_session_id] do
        source = Workflows.get_workflow_session(data[:selected_session_id])
        if source, do: source.title, else: Workflows.default_title(workflow_type)
      else
        Workflows.default_title(workflow_type)
      end

    session_attrs =
      %{
        title: title,
        workflow_type: workflow_type,
        current_phase: phase + 1,
        total_phases: Workflows.total_phases(workflow_type)
      }
      |> maybe_put(:project_id, data[:project_id])
      |> maybe_put(:title_generating, data[:title_generating])

    {:ok, ws} = Workflows.create_workflow_session(session_attrs)

    # Store wizard metadata based on what was provided
    if data[:idea] do
      Workflows.upsert_metadata(ws.id, "wizard", "idea", %{"text" => data[:idea]})
    end

    if data[:prompt] do
      Workflows.upsert_metadata(ws.id, "wizard", "prompt", %{"text" => data[:prompt]})
    end

    if data[:selected_session_id] do
      Workflows.upsert_metadata(ws.id, "wizard", "source_session", %{
        "id" => data[:selected_session_id]
      })
    end

    {:noreply, push_navigate(socket, to: ~p"/sessions/#{ws.id}")}
  end

  # Phase complete — advance to next phase (guard: phase must match current)
  def handle_info({:phase_complete, phase, _data}, socket)
      when phase == socket.assigns.current_phase do
    ws = socket.assigns.workflow_session

    Destila.Executions.Engine.advance_to_next(ws)
    ws = Workflows.get_workflow_session!(ws.id)

    {:noreply,
     socket
     |> assign(:workflow_session, ws)
     |> assign(:current_phase, ws.current_phase)
     |> assign(:metadata, Workflows.get_metadata(ws.id))
     |> assign(:page_title, ws.title)}
  end

  # Stale phase_complete — ignore
  def handle_info({:phase_complete, _stale_phase, _data}, socket) do
    {:noreply, socket}
  end

  def handle_info({:phase_event, _event, _data}, socket) do
    {:noreply, socket}
  end

  # PubSub: workflow session updated — refresh shared chrome
  def handle_info({:workflow_session_updated, updated_ws}, socket) do
    if socket.assigns[:workflow_session] &&
         updated_ws.id == socket.assigns.workflow_session.id do
      ws = Workflows.get_workflow_session!(updated_ws.id)

      {:noreply,
       socket
       |> assign(:workflow_session, ws)
       |> assign(:current_phase, ws.current_phase)
       |> assign(:page_title, ws.title)
       |> assign(
         :streaming_chunks,
         if(ws.phase_status == :processing,
           do: socket.assigns[:streaming_chunks],
           else: nil
         )
       )}
    else
      {:noreply, socket}
    end
  end

  # PubSub: metadata changed — refresh metadata assign for active phase component
  def handle_info({:metadata_updated, ws_id}, socket) do
    if socket.assigns[:workflow_session] && ws_id == socket.assigns.workflow_session.id do
      {:noreply, assign(socket, :metadata, Workflows.get_metadata(ws_id))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:ai_stream_chunk, chunk}, socket) do
    chunks = socket.assigns[:streaming_chunks] || []
    {:noreply, assign(socket, :streaming_chunks, chunks ++ [chunk])}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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

  # --- Render: running workflow ---

  def render(%{view: :running} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} page_title={@page_title}>
      <div class="flex flex-col h-screen">
        <%!-- Header --%>
        <div class="border-b border-base-300 bg-base-100 px-6 py-4">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-4 flex-1 min-w-0">
              <.link navigate={~p"/crafting"} class="btn btn-ghost btn-sm btn-square">
                <.icon name="hero-arrow-left-micro" class="size-4" />
              </.link>

              <div class="flex-1 min-w-0">
                <%= if @workflow_session do %>
                  <div :if={!@editing_title} class="flex items-center gap-2">
                    <h1
                      class={[
                        "text-lg font-bold truncate transition-colors",
                        if(@workflow_session.title_generating,
                          do: "animate-pulse text-base-content/50",
                          else: "cursor-pointer hover:text-primary"
                        )
                      ]}
                      phx-click={if(!@workflow_session.title_generating, do: "edit_title")}
                    >
                      {@workflow_session.title}
                    </h1>
                    <button
                      :if={!@workflow_session.title_generating}
                      phx-click="edit_title"
                      class="cursor-pointer"
                    >
                      <.icon name="hero-pencil-micro" class="size-3.5 text-base-content/30" />
                    </button>
                  </div>

                  <form
                    :if={@editing_title}
                    phx-submit="save_title"
                    class="flex items-center gap-2"
                  >
                    <input
                      type="text"
                      name="title"
                      value={@workflow_session.title}
                      class="input input-bordered input-sm w-full max-w-md"
                      autofocus
                      phx-blur="save_title"
                      phx-value-title={@workflow_session.title}
                    />
                  </form>
                <% else %>
                  <h1 class="text-lg font-bold truncate">
                    {Workflows.default_title(@workflow_type)}
                  </h1>
                <% end %>

                <div class="flex items-center gap-3 mt-1">
                  <.workflow_badge type={@workflow_type} />
                  <span :if={@project} class="text-xs text-base-content/40">
                    <.link
                      navigate={~p"/projects"}
                      class="hover:text-base-content/60 transition-colors"
                    >
                      {@project.name}
                    </.link>
                    <span :if={@project.git_repo_url} class="ml-1">
                      ({@project.git_repo_url})
                    </span>
                  </span>
                </div>
              </div>
            </div>

            <div class="flex items-center gap-3 ml-4">
              <div class="flex items-center gap-2">
                <div class="w-24">
                  <.progress_indicator completed={@current_phase} total={@total_phases} />
                </div>
                <span class="text-xs text-base-content/40">
                  Phase {@current_phase}/{@total_phases}
                  <span
                    :if={Workflows.phase_name(@workflow_type, @current_phase)}
                    class="hidden sm:inline"
                  >
                    — {Workflows.phase_name(@workflow_type, @current_phase)}
                  </span>
                </span>
              </div>

              <%!-- Mark as Done --%>
              <button
                :if={
                  @workflow_session &&
                    @workflow_session.current_phase == @workflow_session.total_phases &&
                    !Session.done?(@workflow_session)
                }
                phx-click="mark_done"
                id="mark-done-btn"
                class="btn btn-success btn-sm"
              >
                <.icon name="hero-check-micro" class="size-4" /> Mark as Done
              </button>

              <%!-- Archive / Unarchive --%>
              <%= if @workflow_session do %>
                <button
                  :if={is_nil(@workflow_session.archived_at)}
                  phx-click="archive_session"
                  id="archive-btn"
                  class="btn btn-soft btn-sm"
                  data-confirm="Archive this session? It will be hidden from the crafting board."
                >
                  <.icon name="hero-archive-box-micro" class="size-4" /> Archive
                </button>
                <button
                  :if={@workflow_session.archived_at}
                  phx-click="unarchive_session"
                  id="unarchive-btn"
                  class="btn btn-soft btn-sm"
                >
                  <.icon name="hero-archive-box-arrow-down-micro" class="size-4" /> Unarchive
                </button>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Phase content — full remaining height, phase manages its own layout --%>
        <div class="flex-1 min-h-0">
          {render_phase(assigns)}
        </div>

        <%!-- Workflow complete banner --%>
        <div
          :if={@workflow_session && Session.done?(@workflow_session)}
          class="border-t border-base-300 bg-base-200/50 px-4 py-3"
        >
          <p class="text-sm text-base-content/50 flex items-center justify-center gap-2">
            <.icon name="hero-check-circle-solid" class="size-4 text-success" />
            <span>Workflow complete</span>
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Generic phase rendering ---

  defp render_phase(%{phases: phases, current_phase: current_phase} = assigns) do
    case Enum.at(phases, current_phase - 1) do
      {module, opts} ->
        assigns = assign(assigns, :phase_module, module)
        assigns = assign(assigns, :phase_opts, opts)

        ~H"""
        <.live_component
          module={@phase_module}
          id={"phase-#{@current_phase}"}
          workflow_session={@workflow_session}
          workflow_type={@workflow_type}
          metadata={@metadata}
          opts={@phase_opts}
          phase_number={@current_phase}
          streaming_chunks={@streaming_chunks}
        />
        """

      nil ->
        ~H"""
        <div class="text-base-content/50 text-center py-12">
          Phase {@current_phase}
        </div>
        """
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
