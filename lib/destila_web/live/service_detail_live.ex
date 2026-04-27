defmodule DestilaWeb.ServiceDetailLive do
  @moduledoc """
  Dedicated page for a development service.

  Branches on `live_action`:
    * `:session` — per-session service running in window 9 of the session's
      tmux session, inside the session's isolated worktree.
    * `:project` — project-level service running against the project's
      primary checkout on the default branch, in a dedicated tmux session.

  Surfaces status, port, commands, lifecycle controls, and a live tail of
  the service log captured via `tmux pipe-pane`.
  """

  use DestilaWeb, :live_view

  require Logger

  alias Destila.{AI, Projects, PubSubHelper, Workflows}
  alias Destila.Projects.Project
  alias Destila.Services.{Logs, ProjectServices, ServiceManager, Target}
  alias DestilaWeb.NotFoundError

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case socket.assigns.live_action do
      :session -> mount_session(id, socket)
      :project -> mount_project(id, socket)
    end
  end

  defp mount_session(id, socket) do
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

    log_key =
      Target.for_session(ws, project: project, worktree_path: worktree_path).log_key

    {:ok,
     socket
     |> assign(:target_kind, :session)
     |> assign(:log_key, log_key)
     |> assign(:workflow_session, ws)
     |> assign(:project, project)
     |> assign(:service_state, service_state)
     |> assign(:worktree_path, worktree_path)
     |> assign(:self_hosted?, false)
     |> assign(:terminal_ready, false)
     |> assign(:pending_bytes, read_initial_log_bytes(log_key))
     |> assign(:page_title, "Service — #{ws.title}")}
  end

  defp mount_project(id, socket) do
    project = Projects.get_project(id)
    if is_nil(project), do: raise(NotFoundError, message: "Project not found")

    unless Project.webservice?(project),
      do: raise(NotFoundError, message: "Service not found")

    unless is_nil(project.archived_at),
      do: raise(NotFoundError, message: "Service not found")

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Destila.PubSub, PubSubHelper.project_service_topic(project.id))
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
    end

    log_key = Target.for_project(project).log_key
    service_state = project.service_state || %{"status" => "stopped"}

    {:ok,
     socket
     |> assign(:target_kind, :project)
     |> assign(:log_key, log_key)
     |> assign(:workflow_session, nil)
     |> assign(:project, project)
     |> assign(:service_state, service_state)
     |> assign(:worktree_path, nil)
     |> assign(:self_hosted?, Projects.self_hosted?(project))
     |> assign(:terminal_ready, false)
     |> assign(:pending_bytes, read_initial_log_bytes(log_key))
     |> assign(:page_title, "Service — #{project.name}")}
  end

  # --- Events ---

  @impl true
  def handle_event("start_service", _params, %{assigns: %{target_kind: :session}} = socket) do
    ws = socket.assigns.workflow_session
    opts = [worktree_path: socket.assigns.worktree_path]
    parent = self()

    Task.start(fn ->
      try do
        case ServiceManager.execute(ws, "start", opts) do
          {:ok, _state} -> :ok
          {:error, reason} -> send(parent, {:service_start_failed, reason})
        end
      rescue
        e ->
          Logger.error(
            "start_service task crashed for #{ws.id}: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )

          send(parent, {:service_start_failed, Exception.message(e)})
      end
    end)

    {:noreply, socket}
  end

  def handle_event("start_service", _params, %{assigns: %{target_kind: :project}} = socket) do
    project = socket.assigns.project
    parent = self()

    Task.start(fn ->
      try do
        case ProjectServices.start(project) do
          {:ok, _state} -> :ok
          {:error, reason} -> send(parent, {:service_start_failed, reason})
        end
      rescue
        e ->
          Logger.error(
            "start_service task crashed for project #{project.id}: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )

          send(parent, {:service_start_failed, Exception.message(e)})
      end
    end)

    {:noreply, socket}
  end

  def handle_event("stop_service", _params, %{assigns: %{target_kind: :session}} = socket) do
    case ServiceManager.execute(socket.assigns.workflow_session, "stop") do
      {:ok, _state} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to stop service: #{reason}")}
    end
  end

  def handle_event("stop_service", _params, %{assigns: %{target_kind: :project}} = socket) do
    case ProjectServices.stop(socket.assigns.project) do
      {:ok, _state} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to stop service: #{inspect(reason)}")}
    end
  end

  def handle_event("restart_service", _params, %{assigns: %{target_kind: :session}} = socket) do
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

  def handle_event("restart_service", _params, %{assigns: %{target_kind: :project}} = socket) do
    project = socket.assigns.project

    Task.start(fn ->
      try do
        ProjectServices.restart(project)
      rescue
        e ->
          Logger.error(
            "restart_service task crashed for project #{project.id}: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )
      end
    end)

    {:noreply, socket}
  end

  def handle_event("pull_and_restart", _params, %{assigns: %{target_kind: :project}} = socket) do
    project_id = socket.assigns.project.id

    Task.start(fn ->
      try do
        ProjectServices.pull_and_restart(project_id)
      rescue
        e ->
          Logger.error(
            "pull_and_restart task crashed for project #{project_id}: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )
      end
    end)

    {:noreply, socket}
  end

  def handle_event("clear_logs", _params, %{assigns: %{target_kind: :session}} = socket) do
    ServiceManager.clear_logs(socket.assigns.workflow_session)
    {:noreply, socket}
  end

  def handle_event("clear_logs", _params, %{assigns: %{target_kind: :project}} = socket) do
    ProjectServices.clear_logs(socket.assigns.project)
    {:noreply, socket}
  end

  def handle_event("remove_service", _params, %{assigns: %{target_kind: :project}} = socket) do
    project = socket.assigns.project

    if Projects.self_hosted?(project) do
      {:noreply, put_flash(socket, :error, "Cannot remove the self-hosted Destila project")}
    else
      :ok = ProjectServices.remove(project)

      {:noreply,
       socket
       |> put_flash(:info, "Service removed")
       |> push_navigate(to: ~p"/services")}
    end
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

  def handle_info({:service_logs_cleared, _key}, socket) do
    {:noreply,
     socket
     |> assign(:pending_bytes, "")
     |> push_event("clear", %{})}
  end

  def handle_info(
        {:project_service_error, stage, details},
        %{assigns: %{target_kind: :project}} = socket
      ) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "Pull failed (#{stage}): #{format_error_details(details)}"
     )}
  end

  def handle_info({:service_start_failed, reason}, socket) do
    {:noreply, put_flash(socket, :error, "Failed to start service: #{reason}")}
  end

  def handle_info({:service_proxy_error, reason}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "Caddy failed to register the route: #{format_proxy_error(reason)}"
     )}
  end

  def handle_info(
        {:workflow_session_updated, updated_ws},
        %{assigns: %{target_kind: :session}} = socket
      ) do
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

  def handle_info(
        {:project_updated, updated_project},
        %{assigns: %{target_kind: :project}} = socket
      ) do
    if updated_project.id == socket.assigns.project.id do
      project = Projects.get_project(updated_project.id) || socket.assigns.project
      service_state = project.service_state || %{"status" => "stopped"}

      {:noreply,
       socket
       |> assign(:project, project)
       |> assign(:service_state, service_state)
       |> assign(:self_hosted?, Projects.self_hosted?(project))
       |> assign(:page_title, "Service — #{project.name}")}
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
                id="back-to-services-link"
                navigate={~p"/services"}
                class="btn btn-ghost btn-sm btn-square"
                aria-label="Back to services"
                title="Back to services"
              >
                <.icon name="hero-arrow-left-micro" class="size-4" />
              </.link>
              <div class="min-w-0">
                <h1 class="text-lg font-bold truncate">{header_title(assigns)}</h1>
                <div class="flex items-center gap-2 text-xs text-base-content/50 mt-1">
                  <span class="font-medium text-base-content/60">{header_kind_label(assigns)}</span>
                  <.status_pill state={@service_state} />
                </div>
              </div>
            </div>

            <div class="flex items-center gap-2">
              <.link
                :if={@target_kind == :session}
                id="open-terminal-link"
                navigate={~p"/sessions/#{@workflow_session.id}/terminal"}
                class="btn btn-soft btn-sm"
                title="Open terminal"
              >
                <.icon name="hero-command-line-micro" class="size-4" /> Terminal
              </.link>
              <.link
                :if={@target_kind == :project}
                id="open-terminal-link"
                navigate={~p"/services/projects/#{@project.id}/terminal"}
                class="btn btn-soft btn-sm"
                title="Open terminal"
              >
                <.icon name="hero-command-line-micro" class="size-4" /> Terminal
              </.link>
              <.url_link
                target_kind={@target_kind}
                project={assigns[:project]}
                workflow_session={assigns[:workflow_session]}
                state={@service_state}
              />
              <.control_buttons state={@service_state} target_kind={@target_kind} />
            </div>
          </div>
        </div>

        <%!-- Self-hosted banner --%>
        <div
          :if={@self_hosted?}
          id="self-hosted-banner"
          role="status"
          class="border-b border-amber-500/30 bg-amber-500/5 px-6 py-3 shrink-0"
        >
          <div class="flex items-start gap-2.5">
            <.icon
              name="hero-exclamation-triangle-micro"
              class="size-4 shrink-0 text-amber-600 dark:text-amber-400 mt-0.5"
            />
            <div class="min-w-0 space-y-0.5 text-xs leading-relaxed">
              <p class="font-semibold text-amber-800 dark:text-amber-200">
                Self-hosted Destila — this is the live process
              </p>
              <p class="text-amber-900/75 dark:text-amber-200/70">
                Restarting terminates this VM; your supervisor (systemd, launchd, etc.) must respawn it. Bookmarked URLs may break when a fresh port is reserved on start.
              </p>
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
                title={Logs.log_path(@log_key)}
              >
                {Path.basename(Logs.log_path(@log_key))}
              </span>
            </div>
            <div
              id={"service-logs-#{@log_key}"}
              phx-hook="ServiceLogViewer"
              phx-update="ignore"
              data-session-id={@log_key}
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
                <div :if={@target_kind == :session}>
                  <dt class="text-base-content/50 text-xs">Session</dt>
                  <dd class="mt-1">
                    <.link
                      id="service-session-link"
                      navigate={~p"/sessions/#{@workflow_session.id}"}
                      class="inline-flex items-center gap-1 text-xs text-primary hover:underline break-all"
                    >
                      {@workflow_session.title}
                      <.icon name="hero-arrow-top-right-on-square-micro" class="size-3 shrink-0" />
                    </.link>
                  </dd>
                </div>

                <div :if={@target_kind == :project}>
                  <dt class="text-base-content/50 text-xs">Project</dt>
                  <dd class="mt-1">
                    <.link
                      id="service-project-link"
                      navigate={~p"/projects"}
                      class="inline-flex items-center gap-1 text-xs text-primary hover:underline break-all"
                    >
                      {@project.name}
                      <.icon name="hero-arrow-top-right-on-square-micro" class="size-3 shrink-0" />
                    </.link>
                  </dd>
                </div>

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

                <div
                  :if={@target_kind == :project and @service_state["default_branch"]}
                  id="default-branch-block"
                >
                  <dt class="text-base-content/50 text-xs">Default branch</dt>
                  <dd class="mt-1">
                    <code
                      id="service-default-branch"
                      class="font-mono text-xs bg-base-200/60 text-base-content/80 rounded-md px-2.5 py-1.5 block break-all"
                    >
                      {@service_state["default_branch"]}
                    </code>
                  </dd>
                </div>

                <div
                  :if={@target_kind == :project and @service_state["last_pulled_at"]}
                  id="last-pulled-at-block"
                >
                  <dt class="text-base-content/50 text-xs">Last pulled</dt>
                  <dd
                    id="service-last-pulled-at"
                    class="mt-1 text-xs text-base-content/80 break-all"
                  >
                    {@service_state["last_pulled_at"]}
                  </dd>
                </div>

                <div :if={@target_kind == :session and @worktree_path} id="worktree-path-block">
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

                <div :if={@target_kind == :project and @project.local_folder} id="local-folder-block">
                  <dt class="text-base-content/50 text-xs">Working directory</dt>
                  <dd class="mt-1">
                    <code
                      id="service-local-folder"
                      class="font-mono text-xs bg-base-200/60 text-base-content/80 rounded-md px-2.5 py-1.5 block break-all"
                      title={@project.local_folder}
                    >
                      {@project.local_folder}
                    </code>
                  </dd>
                </div>
              </dl>

              <div
                :if={@target_kind == :project and not @self_hosted?}
                class="mt-6 pt-4 border-t border-base-300"
              >
                <button
                  id="remove-service-button"
                  type="button"
                  phx-click="remove_service"
                  data-confirm="Remove this project service? Logs and state will be cleared."
                  class="btn btn-soft btn-error btn-sm w-full"
                >
                  <.icon name="hero-trash-micro" class="size-4" /> Remove service
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Private: render helpers ---

  defp header_title(%{target_kind: :session, workflow_session: ws}), do: ws.title
  defp header_title(%{target_kind: :project, project: project}), do: project.name

  defp header_kind_label(%{target_kind: :session}), do: "Session service"
  defp header_kind_label(%{target_kind: :project}), do: "Project service"

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

  attr :target_kind, :atom, required: true
  attr :project, :map, default: nil
  attr :workflow_session, :map, default: nil
  attr :state, :map, required: true

  defp url_link(assigns) do
    url =
      case assigns.target_kind do
        :project ->
          project = %{assigns.project | service_state: assigns.state}
          Destila.Services.Url.for_project(project)

        :session ->
          Destila.Services.Url.for_session(%{
            id: assigns.workflow_session.id,
            service_state: assigns.state
          })
      end

    case url do
      nil ->
        ~H""

      url ->
        label = url_link_label(url, assigns.state["port"])
        assigns = assign(assigns, url: url, label: label)

        ~H"""
        <a
          id="service-url-link"
          href={@url}
          target="_blank"
          rel="noopener noreferrer"
          class="btn btn-soft btn-sm"
          title={"Open #{@url}"}
        >
          <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" /> {@label}
        </a>
        """
    end
  end

  defp url_link_label(url, port) do
    case URI.parse(url) do
      %URI{host: host} when host in [nil, "localhost"] -> "localhost:#{port}"
      %URI{host: host} -> host
      _ -> url
    end
  end

  attr :state, :map, required: true
  attr :target_kind, :atom, required: true

  defp control_buttons(assigns) do
    status = assigns.state["status"] || "stopped"
    active? = status in ["running", "starting"]
    running? = status == "running"
    project? = assigns.target_kind == :project

    assigns =
      assigns
      |> assign(:active?, active?)
      |> assign(:running?, running?)
      |> assign(:project?, project?)

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
        :if={@project?}
        id="pull-and-restart-button"
        type="button"
        phx-click="pull_and_restart"
        class="btn btn-soft btn-sm"
        title="Fetch the default branch and fast-forward, then restart the service"
      >
        <.icon name="hero-arrow-down-tray-micro" class="size-4" /> Pull latest & restart
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

  defp format_error_details(details) when is_binary(details), do: details
  defp format_error_details(details), do: inspect(details)

  defp format_proxy_error({:caddy_status, status, body}) when is_binary(body),
    do: "Caddy returned #{status}: #{body}"

  defp format_proxy_error({:caddy_status, status, body}),
    do: "Caddy returned #{status}: #{inspect(body)}"

  defp format_proxy_error(reason), do: inspect(reason)

  # --- Private: log helpers ---

  defp read_initial_log_bytes(log_key) do
    case File.read(Logs.log_path(log_key)) do
      {:ok, contents} -> contents
      {:error, _} -> ""
    end
  end
end
