defmodule DestilaWeb.DashboardLive do
  use DestilaWeb, :live_view

  import DestilaWeb.BoardComponents

  def mount(_params, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
    end

    current_user = session["current_user"]
    crafting = Destila.Store.list_prompts(:crafting)
    implementation = Destila.Store.list_prompts(:implementation)

    {:ok,
     socket
     |> assign(:current_user, current_user)
     |> assign(:page_title, "Dashboard")
     |> assign(:crafting_prompts, crafting)
     |> assign(:implementation_prompts, implementation)}
  end

  def handle_info({_event, _data}, socket) do
    crafting = Destila.Store.list_prompts(:crafting)
    implementation = Destila.Store.list_prompts(:implementation)

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

  defp column_label(:request), do: "Request"
  defp column_label(:distill), do: "Distill"
  defp column_label(:done), do: "Done"
  defp column_label(:impl_done), do: "Done"
  defp column_label(:todo), do: "Todo"
  defp column_label(:in_progress), do: "In Progress"
  defp column_label(:review), do: "Review"
  defp column_label(:qa), do: "QA"

  def render(assigns) do
    crafting_summary = board_summary(assigns.crafting_prompts, [:request, :distill, :done])

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
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="p-6 lg:p-8 max-w-6xl mx-auto">
        <div class="mb-8">
          <h1 class="text-2xl font-bold tracking-tight">Welcome back, {@current_user.name}</h1>
          <p class="text-base-content/50 mt-1">Here's an overview of your prompt boards.</p>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <%!-- Prompt Crafting Board Preview --%>
          <.link
            navigate={~p"/crafting"}
            class="card bg-base-100 border border-base-300 shadow-sm hover:shadow-md hover:border-base-content/20 transition-all"
          >
            <div class="card-body">
              <div class="flex items-center justify-between mb-4">
                <h2 class="card-title text-lg">Prompt Crafting</h2>
                <.icon name="hero-beaker" class="size-5 text-base-content/30" />
              </div>

              <div class="flex gap-4 mb-4">
                <div :for={{col, cards} <- @crafting_summary} class="flex items-center gap-1.5">
                  <span class="text-xs text-base-content/50">{column_label(col)}</span>
                  <span class="badge badge-sm badge-ghost">{length(cards)}</span>
                </div>
              </div>

              <div class="space-y-2">
                <div
                  :for={prompt <- @crafting_prompts |> Enum.take(3)}
                  class="flex items-center justify-between py-1.5 px-2 bg-base-200/50 rounded-lg"
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
            class="card bg-base-100 border border-base-300 shadow-sm hover:shadow-md hover:border-base-content/20 transition-all"
          >
            <div class="card-body">
              <div class="flex items-center justify-between mb-4">
                <h2 class="card-title text-lg">Implementation</h2>
                <.icon name="hero-rocket-launch" class="size-5 text-base-content/30" />
              </div>

              <div class="flex gap-4 mb-4 flex-wrap">
                <div :for={{col, cards} <- @implementation_summary} class="flex items-center gap-1.5">
                  <span class="text-xs text-base-content/50">{column_label(col)}</span>
                  <span class="badge badge-sm badge-ghost">{length(cards)}</span>
                </div>
              </div>

              <div class="space-y-2">
                <div
                  :for={prompt <- @implementation_prompts |> Enum.take(3)}
                  class="flex items-center justify-between py-1.5 px-2 bg-base-200/50 rounded-lg"
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
