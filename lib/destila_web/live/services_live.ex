defmodule DestilaWeb.ServicesLive do
  @moduledoc """
  Top-level index of development services.

  Renders two sections:
    * **Project services** — project-level services running against the
      project's primary checkout on the default branch.
    * **Session services** — per-session services running against the
      session's isolated worktree.

  Read-only: lifecycle controls (Start / Stop / Restart / Pull / Clear) live
  on the per-target detail pages.
  """

  use DestilaWeb, :live_view

  alias Destila.{Projects, PubSubHelper, Workflows}
  alias Destila.Projects.Project

  @impl true
  def mount(_params, _session, socket) do
    sessions = list_eligible_sessions()
    projects = list_eligible_projects()

    session_ids = MapSet.new(sessions, & &1.id)
    project_ids = MapSet.new(projects, & &1.id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")

      Enum.each(session_ids, fn id ->
        Phoenix.PubSub.subscribe(Destila.PubSub, PubSubHelper.service_topic(id))
      end)

      Enum.each(project_ids, fn id ->
        Phoenix.PubSub.subscribe(Destila.PubSub, PubSubHelper.project_service_topic(id))
      end)
    end

    {:ok,
     socket
     |> assign(:page_title, "Services")
     |> assign(:subscribed_session_ids, session_ids)
     |> assign(:subscribed_project_ids, project_ids)
     |> stream(:project_services, projects)
     |> stream(:session_services, sessions)}
  end

  @impl true
  def handle_info({event, _data}, socket)
      when event in [
             :workflow_session_created,
             :workflow_session_updated,
             :project_created,
             :project_updated,
             :project_deleted
           ] do
    {:noreply, refresh(socket)}
  end

  def handle_info({:service_status, _state}, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private ---

  defp list_eligible_sessions do
    Workflows.list_workflow_sessions()
    |> Enum.filter(&session_eligible?/1)
  end

  defp session_eligible?(%{project: %Project{} = project}), do: Project.webservice?(project)
  defp session_eligible?(_), do: false

  defp list_eligible_projects do
    Projects.list_projects_with_service_state()
    |> Enum.filter(&Project.webservice?/1)
  end

  defp refresh(socket) do
    sessions = list_eligible_sessions()
    projects = list_eligible_projects()

    new_session_ids = MapSet.new(sessions, & &1.id)
    new_project_ids = MapSet.new(projects, & &1.id)
    old_session_ids = socket.assigns.subscribed_session_ids
    old_project_ids = socket.assigns.subscribed_project_ids

    if connected?(socket) do
      reconcile_subscriptions(
        old_session_ids,
        new_session_ids,
        &PubSubHelper.service_topic/1
      )

      reconcile_subscriptions(
        old_project_ids,
        new_project_ids,
        &PubSubHelper.project_service_topic/1
      )
    end

    socket =
      socket
      |> drop_removed(old_session_ids, new_session_ids, :session_services)
      |> insert_all(sessions, :session_services)
      |> drop_removed(old_project_ids, new_project_ids, :project_services)
      |> insert_all(projects, :project_services)

    socket
    |> assign(:subscribed_session_ids, new_session_ids)
    |> assign(:subscribed_project_ids, new_project_ids)
  end

  defp reconcile_subscriptions(old_ids, new_ids, topic_fun) do
    Enum.each(MapSet.difference(new_ids, old_ids), fn id ->
      Phoenix.PubSub.subscribe(Destila.PubSub, topic_fun.(id))
    end)

    Enum.each(MapSet.difference(old_ids, new_ids), fn id ->
      Phoenix.PubSub.unsubscribe(Destila.PubSub, topic_fun.(id))
    end)
  end

  defp drop_removed(socket, old_ids, new_ids, stream_name) do
    Enum.reduce(MapSet.difference(old_ids, new_ids), socket, fn id, acc ->
      stream_delete(acc, stream_name, %{id: id})
    end)
  end

  defp insert_all(socket, items, stream_name) do
    Enum.reduce(items, socket, fn item, acc ->
      stream_insert(acc, stream_name, item)
    end)
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title}>
      <div class="p-6 lg:p-8">
        <div class="mb-6">
          <h1 class="text-2xl font-bold tracking-tight">Services</h1>
          <p class="text-sm text-base-content/50 mt-1">
            Development services across your projects and non-archived sessions
          </p>
        </div>

        <%!-- Project services --%>
        <section class="mb-8">
          <h2 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">
            Project services
          </h2>

          <div
            id="project-services-list"
            phx-update="stream"
            class="flex flex-col gap-2"
          >
            <div
              id="project-services-empty"
              class="hidden only:flex items-center justify-center gap-2 h-16 text-base-content/20 text-sm bg-base-200/20 rounded-xl border border-dashed border-base-300/50"
            >
              <.icon name="hero-server-stack-micro" class="size-4" /> No project services yet
            </div>

            <div
              :for={{dom_id, project} <- @streams.project_services}
              id={dom_id}
              data-project-id={project.id}
              class="flex items-center gap-3 rounded-lg border border-base-300 bg-base-100 hover:bg-base-200/40 transition-colors"
            >
              <.link
                navigate={~p"/services/projects/#{project.id}"}
                id={"project-service-row-#{project.id}"}
                class="flex items-center gap-4 min-w-0 flex-1 px-4 py-3"
              >
                <div class="flex items-center gap-2 w-28 shrink-0">
                  <.status_dot state={service_state(project)} />
                  <span class="text-xs text-base-content/70 capitalize">
                    {status(project)}
                  </span>
                </div>
                <div class="w-20 shrink-0 font-mono tabular-nums text-xs text-base-content/70">
                  <span :if={port(project)}>
                    <span class="text-base-content/35">:</span>{port(project)}
                  </span>
                </div>
                <div class="min-w-0 flex-1">
                  <p class="text-sm font-medium truncate">{project.name}</p>
                  <p class="text-xs text-base-content/50 truncate">
                    {service_state(project)["default_branch"] || "default branch"}
                  </p>
                </div>
              </.link>

              <div :if={running_url(project)} class="shrink-0 pr-4">
                <a
                  id={"project-service-url-#{project.id}"}
                  href={running_url(project)}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="btn btn-soft btn-sm"
                  title={"Open #{running_url(project)}"}
                >
                  <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" />
                  localhost:{port(project)}
                </a>
              </div>
            </div>
          </div>
        </section>

        <%!-- Session services --%>
        <section>
          <h2 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">
            Session services
          </h2>

          <div
            id="session-services-list"
            phx-update="stream"
            class="flex flex-col gap-2"
          >
            <div
              id="session-services-empty"
              class="hidden only:flex items-center justify-center gap-2 h-16 text-base-content/20 text-sm bg-base-200/20 rounded-xl border border-dashed border-base-300/50"
            >
              <.icon name="hero-server-stack-micro" class="size-4" /> No session services yet
            </div>

            <div
              :for={{dom_id, ws} <- @streams.session_services}
              id={dom_id}
              data-session-id={ws.id}
              class="flex items-center gap-3 rounded-lg border border-base-300 bg-base-100 hover:bg-base-200/40 transition-colors"
            >
              <.link
                navigate={~p"/services/sessions/#{ws.id}"}
                id={"service-row-#{ws.id}"}
                class="flex items-center gap-4 min-w-0 flex-1 px-4 py-3"
              >
                <div class="flex items-center gap-2 w-28 shrink-0">
                  <.status_dot state={service_state(ws)} />
                  <span class="text-xs text-base-content/70 capitalize">
                    {status(ws)}
                  </span>
                </div>
                <div class="w-20 shrink-0 font-mono tabular-nums text-xs text-base-content/70">
                  <span :if={port(ws)}>
                    <span class="text-base-content/35">:</span>{port(ws)}
                  </span>
                </div>
                <div class="min-w-0 flex-1">
                  <p class="text-sm font-medium truncate">{ws.title}</p>
                  <p class="text-xs text-base-content/50 truncate">{ws.project.name}</p>
                </div>
              </.link>

              <div :if={running_url(ws)} class="shrink-0 pr-4">
                <a
                  id={"service-url-#{ws.id}"}
                  href={running_url(ws)}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="btn btn-soft btn-sm"
                  title={"Open #{running_url(ws)}"}
                >
                  <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" />
                  localhost:{port(ws)}
                </a>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # --- Private: render helpers ---

  defp service_state(%{service_state: nil}), do: %{"status" => "stopped"}
  defp service_state(%{service_state: state}) when is_map(state), do: state
  defp service_state(_), do: %{"status" => "stopped"}

  defp status(item), do: service_state(item)["status"] || "stopped"

  defp port(item) do
    case service_state(item)["port"] do
      port when is_integer(port) -> port
      _ -> nil
    end
  end

  defp running_url(item) do
    state = service_state(item)

    if state["status"] == "running" and is_integer(state["port"]) do
      "http://localhost:#{state["port"]}"
    end
  end

  attr :state, :map, required: true

  defp status_dot(assigns) do
    status = assigns.state["status"] || "stopped"
    assigns = assign(assigns, :status, status)

    ~H"""
    <span class={[
      "size-1.5 rounded-full shrink-0",
      @status == "running" && "bg-green-500",
      @status == "starting" && "bg-amber-500 animate-pulse",
      @status not in ["running", "starting"] && "bg-base-content/30"
    ]} />
    """
  end
end
