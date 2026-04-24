defmodule DestilaWeb.ServicesLive do
  @moduledoc """
  Top-level index of development services across all non-archived workflow
  sessions whose project is configured as a webservice.

  Read-only: lifecycle controls (Start / Stop / Restart / Clear logs) live on
  the per-session `/services/:id` detail page.
  """

  use DestilaWeb, :live_view

  alias Destila.{PubSubHelper, Workflows}
  alias Destila.Projects.Project

  @impl true
  def mount(_params, _session, socket) do
    sessions = list_eligible_sessions()
    ids = MapSet.new(sessions, & &1.id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")

      Enum.each(ids, fn id ->
        Phoenix.PubSub.subscribe(Destila.PubSub, PubSubHelper.service_topic(id))
      end)
    end

    {:ok,
     socket
     |> assign(:page_title, "Services")
     |> assign(:subscribed_ids, ids)
     |> stream(:services, sessions)}
  end

  @impl true
  def handle_info({event, _data}, socket)
      when event in [
             :workflow_session_created,
             :workflow_session_updated,
             :project_updated,
             :project_deleted
           ] do
    {:noreply, refresh_services(socket)}
  end

  def handle_info({:service_status, _state}, socket) do
    {:noreply, refresh_services(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private ---

  defp list_eligible_sessions do
    Workflows.list_workflow_sessions()
    |> Enum.filter(&eligible?/1)
  end

  defp eligible?(%{project: %Project{} = project}), do: Project.webservice?(project)
  defp eligible?(_), do: false

  defp refresh_services(socket) do
    sessions = list_eligible_sessions()
    new_ids = MapSet.new(sessions, & &1.id)
    old_ids = socket.assigns.subscribed_ids

    added = MapSet.difference(new_ids, old_ids)
    removed = MapSet.difference(old_ids, new_ids)

    if connected?(socket) do
      Enum.each(added, fn id ->
        Phoenix.PubSub.subscribe(Destila.PubSub, PubSubHelper.service_topic(id))
      end)

      Enum.each(removed, fn id ->
        Phoenix.PubSub.unsubscribe(Destila.PubSub, PubSubHelper.service_topic(id))
      end)
    end

    socket =
      Enum.reduce(removed, socket, fn id, acc ->
        stream_delete(acc, :services, %{id: id})
      end)

    socket =
      Enum.reduce(sessions, socket, fn ws, acc ->
        stream_insert(acc, :services, ws)
      end)

    assign(socket, :subscribed_ids, new_ids)
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
            Development services across your non-archived sessions
          </p>
        </div>

        <div
          id="services-list"
          phx-update="stream"
          class="flex flex-col gap-2"
        >
          <div
            id="services-empty"
            class="hidden only:flex items-center justify-center gap-2 h-16 text-base-content/20 text-sm bg-base-200/20 rounded-xl border border-dashed border-base-300/50"
          >
            <.icon name="hero-server-stack-micro" class="size-4" /> No services yet
          </div>

          <div
            :for={{dom_id, ws} <- @streams.services}
            id={dom_id}
            data-session-id={ws.id}
            class="flex items-center gap-3 rounded-lg border border-base-300 bg-base-100 hover:bg-base-200/40 transition-colors"
          >
            <.link
              navigate={~p"/services/#{ws.id}"}
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
      </div>
    </Layouts.app>
    """
  end

  # --- Private: render helpers ---

  defp service_state(%{service_state: nil}), do: %{"status" => "stopped"}
  defp service_state(%{service_state: state}) when is_map(state), do: state
  defp service_state(_), do: %{"status" => "stopped"}

  defp status(ws), do: service_state(ws)["status"] || "stopped"

  defp port(ws) do
    case service_state(ws)["port"] do
      port when is_integer(port) -> port
      _ -> nil
    end
  end

  defp running_url(ws) do
    state = service_state(ws)

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
