defmodule DestilaWeb.ServiceDetailLive do
  @moduledoc """
  Dedicated page for a workflow session's development service.

  Surfaces status, port, commands, lifecycle controls, and a live tail of
  the service log captured via `tmux pipe-pane`.
  """

  use DestilaWeb, :live_view

  require Logger

  alias Destila.{AI, Projects, PubSubHelper, Workflows}
  alias Destila.Projects.Project
  alias Destila.Services.{Logs, ServiceManager}
  alias DestilaWeb.NotFoundError

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    ws = Workflows.get_workflow_session(id)
    if is_nil(ws), do: raise(NotFoundError, message: "Session not found")

    project = ws.project_id && Projects.get_project(ws.project_id)
    if is_nil(project), do: raise(NotFoundError, message: "Service not found")

    unless Project.webservice?(project),
      do: raise(NotFoundError, message: "Service not found")

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Destila.PubSub, PubSubHelper.service_topic(id))
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
    end

    ai_session = AI.get_ai_session_for_workflow(id)
    worktree_path = ai_session && ai_session.worktree_path

    service_state = ws.service_state || %{"status" => "stopped"}

    {:ok,
     socket
     |> assign(:workflow_session, ws)
     |> assign(:project, project)
     |> assign(:service_state, service_state)
     |> assign(:worktree_path, worktree_path)
     |> assign(:terminal_ready, false)
     |> assign(:pending_bytes, read_initial_log_bytes(id))
     |> assign(:page_title, "Service — #{ws.title}")}
  end

  # --- Events ---

  @impl true
  def handle_event("start_service", _params, socket) do
    ws = socket.assigns.workflow_session
    opts = [worktree_path: socket.assigns.worktree_path]

    Task.start(fn ->
      try do
        ServiceManager.execute(ws, "start", opts)
      rescue
        e ->
          Logger.error(
            "start_service task crashed for #{ws.id}: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )
      end
    end)

    {:noreply, socket}
  end

  def handle_event("stop_service", _params, socket) do
    case ServiceManager.execute(socket.assigns.workflow_session, "stop") do
      {:ok, _state} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to stop service: #{reason}")}
    end
  end

  def handle_event("restart_service", _params, socket) do
    ws = socket.assigns.workflow_session
    opts = [worktree_path: socket.assigns.worktree_path]

    Task.start(fn ->
      try do
        ServiceManager.execute(ws, "restart", opts)
      rescue
        e ->
          Logger.error(
            "restart_service task crashed for #{ws.id}: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )
      end
    end)

    {:noreply, socket}
  end

  def handle_event("clear_logs", _params, socket) do
    ServiceManager.clear_logs(socket.assigns.workflow_session)
    {:noreply, socket}
  end

  def handle_event("terminal_ready", _params, socket) do
    socket = assign(socket, :terminal_ready, true)

    case socket.assigns.pending_bytes do
      "" ->
        {:noreply, socket}

      bytes ->
        {:noreply,
         socket
         |> assign(:pending_bytes, "")
         |> push_event("output", %{data: Base.encode64(bytes)})}
    end
  end

  # --- Info ---

  @impl true
  def handle_info({:service_status, state}, socket) do
    {:noreply, assign(socket, :service_state, state)}
  end

  def handle_info({:service_log, chunk}, socket) when is_binary(chunk) do
    if socket.assigns.terminal_ready do
      {:noreply, push_event(socket, "output", %{data: Base.encode64(chunk)})}
    else
      {:noreply, assign(socket, :pending_bytes, socket.assigns.pending_bytes <> chunk)}
    end
  end

  def handle_info({:service_logs_cleared, ws_id}, socket) do
    if ws_id == socket.assigns.workflow_session.id do
      {:noreply,
       socket
       |> assign(:pending_bytes, "")
       |> push_event("clear", %{})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:workflow_session_updated, updated_ws}, socket) do
    if updated_ws.id == socket.assigns.workflow_session.id do
      ws = Workflows.get_workflow_session(updated_ws.id) || socket.assigns.workflow_session
      service_state = ws.service_state || %{"status" => "stopped"}

      {:noreply,
       socket
       |> assign(:workflow_session, ws)
       |> assign(:service_state, service_state)
       |> assign(:page_title, "Service — #{ws.title}")}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title}>
      <div class="flex flex-col h-screen">
        <%!-- Header --%>
        <div class="border-b border-base-300 bg-base-100 px-6 py-4 shrink-0">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-4 min-w-0">
              <.link
                id="back-to-session-link"
                navigate={~p"/sessions/#{@workflow_session.id}"}
                class="btn btn-ghost btn-sm btn-square"
                aria-label="Back to session"
                title="Back to session"
              >
                <.icon name="hero-arrow-left-micro" class="size-4" />
              </.link>
              <div class="min-w-0">
                <h1 class="text-lg font-bold truncate">{@workflow_session.title}</h1>
                <div class="flex items-center gap-2 text-xs text-base-content/50 mt-1">
                  <span class="font-medium text-base-content/60">Service</span>
                  <.status_pill state={@service_state} />
                </div>
              </div>
            </div>

            <div class="flex items-center gap-2">
              <.link
                id="open-terminal-link"
                navigate={~p"/sessions/#{@workflow_session.id}/terminal"}
                class="btn btn-soft btn-sm"
                title="Open terminal"
              >
                <.icon name="hero-command-line-micro" class="size-4" /> Terminal
              </.link>
              <.url_link state={@service_state} />
              <.control_buttons state={@service_state} />
            </div>
          </div>
        </div>

        <%!-- Body --%>
        <div class="flex-1 min-h-0 flex flex-col lg:flex-row gap-4 p-6 overflow-hidden">
          <%!-- Log viewer --%>
          <div class="flex-1 min-h-0 min-w-0 flex flex-col rounded-lg border border-base-300 bg-base-200/30 overflow-hidden">
            <div class="px-4 py-2.5 border-b border-base-300 bg-base-100 flex items-center justify-between gap-4 shrink-0">
              <h2 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider shrink-0">
                Logs
              </h2>
              <span
                class="text-[11px] text-base-content/40 font-mono truncate min-w-0"
                title={Logs.log_path(@workflow_session.id)}
              >
                {Path.basename(Logs.log_path(@workflow_session.id))}
              </span>
            </div>
            <div
              id={"service-logs-#{@workflow_session.id}"}
              phx-hook="ServiceLogViewer"
              phx-update="ignore"
              data-session-id={@workflow_session.id}
              class="flex-1 min-h-0 overflow-hidden"
            >
              <div data-terminal-container class="h-full w-full p-2" />
            </div>
          </div>

          <%!-- Details card --%>
          <div class="lg:w-80 shrink-0 flex flex-col gap-4">
            <div class="rounded-lg border border-base-300 bg-base-100 p-4">
              <h2 class="text-xs font-semibold text-base-content/40 uppercase tracking-wider mb-3">
                Details
              </h2>

              <dl class="space-y-3 text-sm">
                <div>
                  <dt class="text-base-content/50 text-xs">Status</dt>
                  <dd
                    id="service-status-text"
                    class="mt-1 flex items-center gap-2 text-xs text-base-content/80 capitalize"
                  >
                    <.status_dot state={@service_state} />
                    {@service_state["status"] || "stopped"}
                  </dd>
                </div>

                <div :if={@service_state["port"]}>
                  <dt class="text-base-content/50 text-xs">Port</dt>
                  <dd
                    id="service-port-text"
                    class="mt-1 font-mono tabular-nums text-xs text-base-content/80"
                  >
                    <span class="text-base-content/35">:</span>{@service_state["port"]}
                  </dd>
                </div>

                <div :if={run_command(@project, @service_state)} id="run-command-block">
                  <dt class="text-base-content/50 text-xs">Run command</dt>
                  <dd class="mt-1">
                    <code
                      id="service-run-command"
                      class="font-mono text-xs bg-base-200/60 text-base-content/80 rounded-md px-2.5 py-1.5 block break-all"
                    >
                      {run_command(@project, @service_state)}
                    </code>
                  </dd>
                </div>

                <div :if={setup_command(@project, @service_state)} id="setup-command-block">
                  <dt class="text-base-content/50 text-xs">Setup command</dt>
                  <dd class="mt-1">
                    <code
                      id="service-setup-command"
                      class="font-mono text-xs bg-base-200/60 text-base-content/80 rounded-md px-2.5 py-1.5 block break-all"
                    >
                      {setup_command(@project, @service_state)}
                    </code>
                  </dd>
                </div>

                <div :if={@worktree_path} id="worktree-path-block">
                  <dt class="text-base-content/50 text-xs">Worktree</dt>
                  <dd class="mt-1">
                    <code
                      id="service-worktree-path"
                      class="font-mono text-xs bg-base-200/60 text-base-content/80 rounded-md px-2.5 py-1.5 block break-all"
                      title={@worktree_path}
                    >
                      {@worktree_path}
                    </code>
                  </dd>
                </div>
              </dl>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Private: render helpers ---

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

  attr :state, :map, required: true

  defp status_pill(assigns) do
    status = assigns.state["status"] || "stopped"
    assigns = assign(assigns, :status, status)

    ~H"""
    <span
      id="service-status-pill"
      class={[
        "inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[10px] font-semibold uppercase tracking-wider",
        @status == "running" && "bg-green-500/10 text-green-600 dark:text-green-400",
        @status == "starting" && "bg-amber-500/10 text-amber-600 dark:text-amber-400",
        @status not in ["running", "starting"] && "bg-base-300/40 text-base-content/50"
      ]}
    >
      <span class={[
        "size-1.5 rounded-full",
        @status == "running" && "bg-green-500",
        @status == "starting" && "bg-amber-500 animate-pulse",
        @status not in ["running", "starting"] && "bg-base-content/30"
      ]} />
      {@status}
    </span>
    """
  end

  attr :state, :map, required: true

  defp url_link(assigns) do
    status = assigns.state["status"]
    port = assigns.state["port"]

    cond do
      status == "running" and is_integer(port) ->
        assigns = assign(assigns, :port, port)

        ~H"""
        <a
          id="service-url-link"
          href={"http://localhost:#{@port}"}
          target="_blank"
          rel="noopener noreferrer"
          class="btn btn-soft btn-sm"
          title={"Open http://localhost:#{@port}"}
        >
          <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" /> localhost:{@port}
        </a>
        """

      true ->
        ~H""
    end
  end

  attr :state, :map, required: true

  defp control_buttons(assigns) do
    status = assigns.state["status"] || "stopped"
    active? = status in ["running", "starting"]
    running? = status == "running"

    assigns =
      assigns
      |> assign(:active?, active?)
      |> assign(:running?, running?)

    ~H"""
    <div class="flex items-center gap-2">
      <button
        :if={not @active?}
        id="start-service-button"
        type="button"
        phx-click="start_service"
        class="btn btn-primary btn-sm"
      >
        <.icon name="hero-play-micro" class="size-4" /> Start
      </button>
      <button
        :if={@active?}
        id="stop-service-button"
        type="button"
        phx-click="stop_service"
        class="btn btn-error btn-sm"
      >
        <.icon name="hero-stop-micro" class="size-4" /> Stop
      </button>
      <button
        :if={@running?}
        id="restart-service-button"
        type="button"
        phx-click="restart_service"
        class="btn btn-soft btn-sm"
      >
        <.icon name="hero-arrow-path-micro" class="size-4" /> Restart
      </button>
      <button
        id="clear-logs-button"
        type="button"
        phx-click="clear_logs"
        class="btn btn-soft btn-sm"
        title="Clear logs"
      >
        <.icon name="hero-trash-micro" class="size-4" /> Clear logs
      </button>
    </div>
    """
  end

  # --- Private: state helpers ---

  defp run_command(project, state) do
    (state["run_command"] || project.run_command)
    |> presence()
  end

  defp setup_command(project, state) do
    (state["setup_command"] || project.setup_command)
    |> presence()
  end

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # --- Private: log helpers ---

  defp read_initial_log_bytes(ws_id) do
    case File.read(Logs.log_path(ws_id)) do
      {:ok, contents} -> contents
      {:error, _} -> ""
    end
  end
end
