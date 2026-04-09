defmodule DestilaWeb.ArchivedSessionsLive do
  use DestilaWeb, :live_view

  import DestilaWeb.BoardComponents, only: [workflow_badge: 1, progress_indicator: 1]

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
    end

    sessions = Destila.Workflows.list_archived_workflow_sessions()

    {:ok,
     socket
     |> assign(:page_title, "Archived Sessions")
     |> assign(:sessions, sessions)}
  end

  def handle_info({event, _data}, socket)
      when event in [
             :workflow_session_created,
             :workflow_session_updated
           ] do
    sessions = Destila.Workflows.list_archived_workflow_sessions()
    {:noreply, assign(socket, :sessions, sessions)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title}>
      <div class="p-6 lg:p-8">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-2xl font-bold tracking-tight">Archived Sessions</h1>
          <.link
            navigate={~p"/crafting"}
            class="text-xs text-base-content/40 hover:text-base-content/60 transition-colors flex items-center gap-1"
          >
            <.icon name="hero-arrow-left-micro" class="size-3.5" /> Back to Crafting Board
          </.link>
        </div>

        <%= if @sessions == [] do %>
          <div
            id="archived-empty"
            class="flex items-center justify-center gap-2 h-16 text-base-content/20 text-sm bg-base-200/20 rounded-xl border border-dashed border-base-300/50"
          >
            <.icon name="hero-archive-box-micro" class="size-4" /> No archived sessions
          </div>
        <% else %>
          <div
            id="archived-list"
            class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-3"
          >
            <.link
              :for={ws <- @sessions}
              navigate={~p"/sessions/#{ws.id}"}
              id={"archived-session-#{ws.id}"}
              class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow"
            >
              <div class="card-body p-4 gap-2">
                <p class="text-sm font-medium leading-tight truncate">{ws.title}</p>
                <div class="flex items-center justify-between gap-2">
                  <div class="flex items-center gap-2">
                    <.workflow_badge type={ws.workflow_type} />
                    <span :if={ws.project} class="text-xs text-base-content/60 truncate max-w-[120px]">
                      {ws.project.name}
                    </span>
                  </div>
                  <span class="text-xs text-base-content/40 whitespace-nowrap">
                    {ws.current_phase}/{ws.total_phases}
                  </span>
                </div>
                <.progress_indicator
                  completed={ws.current_phase}
                  total={ws.total_phases}
                />
              </div>
            </.link>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
