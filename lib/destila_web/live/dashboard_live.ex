defmodule DestilaWeb.DashboardLive do
  use DestilaWeb, :live_view

  import DestilaWeb.BoardComponents

  def mount(_params, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
    end

    current_user = session["current_user"]
    crafting = Destila.Prompts.list_prompts(:crafting)
    implementation = Destila.Prompts.list_prompts(:implementation)

    {:ok,
     socket
     |> assign(:current_user, current_user)
     |> assign(:page_title, "Dashboard")
     |> assign(:crafting_prompts, crafting)
     |> assign(:implementation_prompts, implementation)}
  end

  def handle_info({_event, _data}, socket) do
    crafting = Destila.Prompts.list_prompts(:crafting)
    implementation = Destila.Prompts.list_prompts(:implementation)

    {:noreply,
     socket
     |> assign(:crafting_prompts, crafting)
     |> assign(:implementation_prompts, implementation)}
  end

  defp board_summary(prompts, columns) do
    Enum.map(columns, fn col ->
      cards = Enum.filter(prompts, &(&1.column == col))
      {col, cards}
    end)
  end

  defp crafting_summary(prompts) do
    grouped = Enum.group_by(prompts, &classify_crafting_prompt/1)

    Enum.map([:setup, :waiting, :in_progress, :done], fn section ->
      {section, Map.get(grouped, section, [])}
    end)
  end

  defp classify_crafting_prompt(prompt) do
    cond do
      prompt.column == :done -> :done
      prompt.phase_status == :setup -> :setup
      prompt.phase_status in [:generating, :conversing, :advance_suggested] -> :waiting
      true -> :in_progress
    end
  end

  defp section_label(:setup), do: "Setup"
  defp section_label(:waiting), do: "Waiting"
  defp section_label(:in_progress), do: "In Progress"
  defp section_label(:done), do: "Done"

  defp column_label(:impl_done), do: "Done"
  defp column_label(:todo), do: "Todo"
  defp column_label(:in_progress), do: "In Progress"
  defp column_label(:review), do: "Review"
  defp column_label(:qa), do: "QA"

  def render(assigns) do
    crafting_summary = crafting_summary(assigns.crafting_prompts)

    implementation_summary =
      board_summary(assigns.implementation_prompts, [
        :todo,
        :in_progress,
        :review,
        :qa,
        :impl_done
      ])

    assigns =
      assigns
      |> assign(:crafting_summary, crafting_summary)
      |> assign(:implementation_summary, implementation_summary)

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} page_title={@page_title}>
      <div class="p-6 lg:p-8 max-w-6xl mx-auto">
        <h1 class="text-2xl font-bold tracking-tight mb-8">
          Welcome back, {@current_user.name}
        </h1>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <%!-- Prompt Crafting Board Preview --%>
          <.link
            navigate={~p"/crafting"}
            class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow"
          >
            <div class="card-body">
              <h2 class="card-title text-lg mb-1">Prompt Crafting</h2>

              <div class="flex gap-3 text-xs text-base-content/50 mb-3">
                <span :for={{section, cards} <- @crafting_summary}>
                  {length(cards)} {section_label(section)}
                </span>
              </div>

              <div class="divide-y divide-base-200">
                <div
                  :for={prompt <- @crafting_prompts |> Enum.take(3)}
                  class="flex items-center justify-between py-2"
                >
                  <span class="text-sm truncate mr-2">{prompt.title}</span>
                  <.workflow_badge type={prompt.workflow_type} />
                </div>
              </div>
            </div>
          </.link>

          <%!-- Implementation Board Preview --%>
          <.link
            navigate={~p"/implementation"}
            class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow"
          >
            <div class="card-body">
              <h2 class="card-title text-lg mb-1">Implementation</h2>

              <div class="flex gap-3 text-xs text-base-content/50 mb-3 flex-wrap">
                <span :for={{col, cards} <- @implementation_summary}>
                  {length(cards)} {column_label(col)}
                </span>
              </div>

              <div class="divide-y divide-base-200">
                <div
                  :for={prompt <- @implementation_prompts |> Enum.take(3)}
                  class="flex items-center justify-between py-2"
                >
                  <span class="text-sm truncate mr-2">{prompt.title}</span>
                  <.workflow_badge type={prompt.workflow_type} />
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
