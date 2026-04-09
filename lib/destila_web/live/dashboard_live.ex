defmodule DestilaWeb.DashboardLive do
  use DestilaWeb, :live_view

  import DestilaWeb.BoardComponents

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
    end

    crafting = Destila.Workflows.list_workflow_sessions()

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:crafting_prompts, crafting)}
  end

  def handle_info({event, _data}, socket)
      when event in [
             :workflow_session_created,
             :workflow_session_updated
           ] do
    crafting = Destila.Workflows.list_workflow_sessions()

    {:noreply,
     socket
     |> assign(:crafting_prompts, crafting)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp crafting_summary(prompts) do
    grouped = Enum.group_by(prompts, &classify_crafting_prompt/1)

    Enum.map([:waiting_for_user, :processing, :done], fn section ->
      {section, Map.get(grouped, section, [])}
    end)
  end

  defp classify_crafting_prompt(prompt), do: Destila.Workflows.classify(prompt)

  defp section_label(:waiting_for_user), do: "Waiting for You"
  defp section_label(:processing), do: "Processing"
  defp section_label(:done), do: "Done"

  def render(assigns) do
    crafting_summary = crafting_summary(assigns.crafting_prompts)

    assigns =
      assigns
      |> assign(:crafting_summary, crafting_summary)

    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title}>
      <div class="p-6 lg:p-8 max-w-6xl mx-auto">
        <h1 class="text-2xl font-bold tracking-tight mb-8">
          Dashboard
        </h1>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <%!-- Crafting Board Preview --%>
          <.link
            navigate={~p"/crafting"}
            class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow"
          >
            <div class="card-body">
              <h2 class="card-title text-lg mb-1">Crafting Board</h2>

              <div class="flex gap-3 text-xs text-base-content/50 mb-3">
                <span :for={{section, cards} <- @crafting_summary}>
                  {length(cards)} {section_label(section)}
                </span>
              </div>

              <div class="divide-y divide-base-200">
                <div
                  :for={ws <- @crafting_prompts |> Enum.take(3)}
                  class="flex items-center justify-between py-2"
                >
                  <span class="text-sm truncate mr-2 min-w-0">{ws.title}</span>
                  <.workflow_badge type={ws.workflow_type} />
                </div>
              </div>
            </div>
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
