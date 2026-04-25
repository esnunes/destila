defmodule DestilaWeb.TerminalLive do
  use DestilaWeb, :live_view

  alias Destila.AI
  alias Destila.Projects
  alias Destila.Services.Target
  alias Destila.Terminal.Server, as: TerminalServer
  alias Destila.Terminal.Tmux
  alias Destila.Workflows

  @impl true
  def mount(params, _session, socket) do
    case socket.assigns.live_action do
      :session -> mount_session(params, socket)
      :project -> mount_project(params, socket)
    end
  end

  defp mount_session(%{"id" => id}, socket) do
    case Workflows.get_workflow_session(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Session not found")
         |> push_navigate(to: ~p"/crafting")}

      ws ->
        ai_session = AI.get_ai_session_for_workflow(ws.id)
        cwd = ai_session && ai_session.worktree_path

        if cwd do
          topic = "terminal:#{ws.id}"
          if connected?(socket), do: Phoenix.PubSub.subscribe(Destila.PubSub, topic)

          {:ok,
           socket
           |> assign(:target_kind, :session)
           |> assign(:workflow_session, ws)
           |> assign(:project, nil)
           |> assign(:cwd, cwd)
           |> assign(:topic, topic)
           |> assign(:tmux_session_name, Tmux.session_name(ws))
           |> assign(:claude_session_id, ai_session.claude_session_id)
           |> assign(:terminal_pid, nil)
           |> assign(:back_path, ~p"/sessions/#{ws.id}")
           |> assign(:terminal_id, ws.id)
           |> assign(:title, ws.title)
           |> assign(:page_title, "Terminal — #{ws.title}")}
        else
          {:ok,
           socket
           |> put_flash(:error, "No worktree path for this session")
           |> push_navigate(to: ~p"/sessions/#{id}")}
        end
    end
  end

  defp mount_project(%{"id" => id}, socket) do
    case Projects.get_project(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Project not found")
         |> push_navigate(to: ~p"/services")}

      project ->
        target = Target.for_project(project)

        if is_binary(target.cwd) and target.cwd != "" do
          topic = "terminal:project-#{project.id}"
          if connected?(socket), do: Phoenix.PubSub.subscribe(Destila.PubSub, topic)

          {:ok,
           socket
           |> assign(:target_kind, :project)
           |> assign(:workflow_session, nil)
           |> assign(:project, project)
           |> assign(:cwd, target.cwd)
           |> assign(:topic, topic)
           |> assign(:tmux_session_name, target.tmux_session_name)
           |> assign(:claude_session_id, nil)
           |> assign(:terminal_pid, nil)
           |> assign(:back_path, ~p"/services/projects/#{project.id}")
           |> assign(:terminal_id, "project-#{project.id}")
           |> assign(:title, project.name)
           |> assign(:page_title, "Terminal — #{project.name}")}
        else
          {:ok,
           socket
           |> put_flash(:error, "Project has no working directory")
           |> push_navigate(to: ~p"/services/projects/#{project.id}")}
        end
    end
  end

  @impl true
  def handle_event("terminal_ready", _params, socket) do
    {:ok, pid} =
      TerminalServer.start_link(
        cwd: socket.assigns.cwd,
        topic: socket.assigns.topic,
        session_name: socket.assigns.tmux_session_name,
        claude_session_id: socket.assigns.claude_session_id
      )

    {:noreply, assign(socket, :terminal_pid, pid)}
  end

  def handle_event("input", %{"data" => data}, socket) do
    if pid = socket.assigns.terminal_pid, do: TerminalServer.write(pid, data)
    {:noreply, socket}
  end

  def handle_event("resize", %{"cols" => cols, "rows" => rows}, socket) do
    if pid = socket.assigns.terminal_pid, do: TerminalServer.resize(pid, cols, rows)
    {:noreply, socket}
  end

  def handle_event("terminal_exited", _params, socket) do
    {:noreply, push_navigate(socket, to: socket.assigns.back_path)}
  end

  @impl true
  def handle_info({:terminal_output, data}, socket) do
    {:noreply, push_event(socket, "output", %{data: Base.encode64(data)})}
  end

  def handle_info(:terminal_exited, socket) do
    {:noreply, push_event(socket, "exited", %{})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title}>
      <div class="flex flex-col h-screen bg-base-200">
        <%!-- Header --%>
        <div class="flex items-center gap-3 px-4 py-2.5 border-b border-base-300 bg-base-100 shrink-0">
          <.link
            navigate={@back_path}
            class="btn btn-ghost btn-sm btn-square"
          >
            <.icon name="hero-arrow-left-micro" class="size-4" />
          </.link>
          <div class="flex items-center gap-2 min-w-0">
            <.icon name="hero-command-line-micro" class="size-4 text-base-content/40" />
            <span class="text-sm text-base-content/60 truncate">
              {@title}
            </span>
          </div>
        </div>

        <%!-- Terminal container with inset padding --%>
        <div class="flex-1 min-h-0 p-2 pt-0">
          <div
            id={"terminal-panel-#{@terminal_id}"}
            phx-hook="TerminalPanel"
            phx-update="ignore"
            data-session-id={@terminal_id}
            class="h-full rounded-b-lg overflow-hidden"
          >
            <div data-terminal-container class="h-full" />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
