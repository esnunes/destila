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

    {initial_lines, next_id, buffer} = load_initial_log_lines(id)

    {:ok,
     socket
     |> assign(:workflow_session, ws)
     |> assign(:project, project)
     |> assign(:service_state, service_state)
     |> assign(:worktree_path, worktree_path)
     |> assign(:log_buffer, buffer)
     |> assign(:next_log_id, next_id)
     |> assign(:page_title, "Service — #{ws.title}")
     |> stream(:log_lines, initial_lines, reset: true)}
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

  # --- Info ---

  @impl true
  def handle_info({:service_status, state}, socket) do
    {:noreply, assign(socket, :service_state, state)}
  end

  def handle_info({:service_log, chunk}, socket) when is_binary(chunk) do
    buffer = socket.assigns.log_buffer <> chunk

    {complete, remainder} = split_on_last_newline(buffer)

    if complete == "" do
      {:noreply, assign(socket, :log_buffer, remainder)}
    else
      lines = String.split(complete, "\n", trim: false) |> drop_trailing_empty()
      {socket, next_id} = push_lines(socket, lines, socket.assigns.next_log_id)

      {:noreply,
       socket
       |> assign(:log_buffer, remainder)
       |> assign(:next_log_id, next_id)}
    end
  end

  def handle_info({:service_logs_cleared, ws_id}, socket) do
    if ws_id == socket.assigns.workflow_session.id do
      {:noreply,
       socket
       |> assign(:log_buffer, "")
       |> assign(:next_log_id, 0)
       |> stream(:log_lines, [], reset: true)}
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
              <.url_link state={@service_state} />
              <.control_buttons state={@service_state} />
            </div>
          </div>
        </div>

        <%!-- Body --%>
        <div class="flex-1 min-h-0 flex flex-col lg:flex-row gap-4 p-6 overflow-hidden">
          <%!-- Details card --%>
          <div class="lg:w-80 shrink-0 flex flex-col gap-4">
            <div class="rounded-lg border border-base-300 bg-base-100 p-4">
              <h2 class="text-xs font-semibold text-base-content/40 uppercase tracking-wider mb-3">
                Details
              </h2>

              <dl class="space-y-3 text-sm">
                <div>
                  <dt class="text-base-content/50 text-xs">Status</dt>
                  <dd id="service-status-text" class="font-mono text-base-content/80 mt-0.5">
                    {@service_state["status"] || "stopped"}
                  </dd>
                </div>

                <div :if={@service_state["port"]}>
                  <dt class="text-base-content/50 text-xs">Port</dt>
                  <dd id="service-port-text" class="font-mono text-base-content/80 mt-0.5">
                    {@service_state["port"]}
                  </dd>
                </div>

                <div :if={run_command(@project, @service_state)} id="run-command-block">
                  <dt class="text-base-content/50 text-xs">Run command</dt>
                  <dd class="mt-0.5">
                    <code
                      id="service-run-command"
                      class="font-mono text-xs bg-base-200/60 rounded px-2 py-1 block whitespace-pre-wrap break-all"
                    >
                      {run_command(@project, @service_state)}
                    </code>
                  </dd>
                </div>

                <div :if={setup_command(@project, @service_state)} id="setup-command-block">
                  <dt class="text-base-content/50 text-xs">Setup command</dt>
                  <dd class="mt-0.5">
                    <code
                      id="service-setup-command"
                      class="font-mono text-xs bg-base-200/60 rounded px-2 py-1 block whitespace-pre-wrap break-all"
                    >
                      {setup_command(@project, @service_state)}
                    </code>
                  </dd>
                </div>
              </dl>
            </div>
          </div>

          <%!-- Log viewer --%>
          <div class="flex-1 min-h-0 min-w-0 flex flex-col rounded-lg border border-base-300 bg-base-900/5 overflow-hidden">
            <div class="px-4 py-2.5 border-b border-base-300 bg-base-200/40 flex items-center justify-between shrink-0">
              <h2 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
                Logs
              </h2>
              <span class="text-[10px] text-base-content/40 font-mono">
                {Destila.Services.Logs.log_path(@workflow_session.id)}
              </span>
            </div>
            <div
              id="service-logs"
              phx-update="stream"
              class="flex-1 min-h-0 overflow-y-auto p-4 font-mono text-xs leading-relaxed whitespace-pre-wrap"
            >
              <div
                id="service-logs-empty"
                class="hidden only:block text-base-content/40 italic"
              >
                No logs yet.
              </div>
              <div
                :for={{dom_id, line} <- @streams.log_lines}
                id={dom_id}
                class="text-base-content/80"
              >
                {line.text}
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Private: render helpers ---

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
  defp presence(""), do: nil

  defp presence(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  # --- Private: log helpers ---

  defp load_initial_log_lines(ws_id) do
    path = Logs.log_path(ws_id)

    case File.read(path) do
      {:ok, contents} ->
        build_lines_from_string(contents)

      {:error, _} ->
        {[], 0, ""}
    end
  end

  defp build_lines_from_string(contents) do
    {complete, remainder} = split_on_last_newline(contents)

    if complete == "" do
      {[], 0, remainder}
    else
      lines =
        complete
        |> String.split("\n", trim: false)
        |> drop_trailing_empty()

      {entries, next_id} =
        Enum.map_reduce(lines, 0, fn text, id ->
          {%{id: id, text: text}, id + 1}
        end)

      {entries, next_id, remainder}
    end
  end

  defp split_on_last_newline(binary) do
    case :binary.matches(binary, "\n") do
      [] ->
        {"", binary}

      matches ->
        {last_idx, 1} = List.last(matches)
        before = binary_part(binary, 0, last_idx + 1)
        after_ = binary_part(binary, last_idx + 1, byte_size(binary) - last_idx - 1)
        {before, after_}
    end
  end

  defp drop_trailing_empty(list) do
    case List.last(list) do
      "" -> Enum.drop(list, -1)
      nil -> list
      _ -> list
    end
  end

  defp push_lines(socket, lines, next_id) do
    Enum.reduce(lines, {socket, next_id}, fn text, {acc_socket, id} ->
      entry = %{id: id, text: text}
      {stream_insert(acc_socket, :log_lines, entry, at: -1), id + 1}
    end)
  end
end
