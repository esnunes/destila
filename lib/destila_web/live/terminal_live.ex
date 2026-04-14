defmodule DestilaWeb.TerminalLive do
  use DestilaWeb, :live_view

  alias Destila.AI
  alias Destila.Terminal.Server, as: TerminalServer
  alias Destila.Workflows

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    ws = Workflows.get_workflow_session(id)

    if ws do
      ai_session = AI.get_ai_session_for_workflow(ws.id)
      cwd = ai_session && ai_session.worktree_path

      if cwd do
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Destila.PubSub, "terminal:#{ws.id}")
        end

        {:ok,
         socket
         |> assign(:workflow_session, ws)
         |> assign(:ai_session, ai_session)
         |> assign(:page_title, "Terminal — #{ws.title}")}
      else
        {:ok,
         socket
         |> put_flash(:error, "No worktree path for this session")
         |> push_navigate(to: ~p"/sessions/#{id}")}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Session not found")
       |> push_navigate(to: ~p"/crafting")}
    end
  end

  @impl true
  def handle_event("terminal_ready", _params, socket) do
    ws = socket.assigns.workflow_session
    ai_session = socket.assigns.ai_session

    {:ok, pid} =
      TerminalServer.start_link(
        cwd: ai_session.worktree_path,
        topic: "terminal:#{ws.id}",
        session_name: Destila.Terminal.Tmux.session_name(ws),
        claude_session_id: ai_session.claude_session_id
      )

    {:noreply, assign(socket, :terminal_pid, pid)}
  end

  def handle_event("input", %{"data" => data}, socket) do
    TerminalServer.write(socket.assigns.terminal_pid, data)
    {:noreply, socket}
  end

  def handle_event("resize", %{"cols" => cols, "rows" => rows}, socket) do
    TerminalServer.resize(socket.assigns.terminal_pid, cols, rows)
    {:noreply, socket}
  end

  def handle_event("terminal_exited", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/sessions/#{socket.assigns.workflow_session.id}")}
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
            navigate={~p"/sessions/#{@workflow_session.id}"}
            class="btn btn-ghost btn-sm btn-square"
          >
            <.icon name="hero-arrow-left-micro" class="size-4" />
          </.link>
          <div class="flex items-center gap-2 min-w-0">
            <.icon name="hero-command-line-micro" class="size-4 text-base-content/40" />
            <span class="text-sm text-base-content/60 truncate">
              {@workflow_session.title}
            </span>
          </div>
        </div>

        <%!-- Terminal container with inset padding --%>
        <div class="flex-1 min-h-0 p-2 pt-0">
          <div
            id={"terminal-panel-#{@workflow_session.id}"}
            phx-hook="TerminalPanel"
            phx-update="ignore"
            data-session-id={@workflow_session.id}
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
