defmodule DestilaWeb.BoardComponents do
  use Phoenix.Component

  attr :title, :string, required: true
  attr :column, :atom, required: true
  attr :cards, :list, required: true
  attr :id, :string, required: true
  attr :sortable, :boolean, default: false

  def board_column(assigns) do
    ~H"""
    <div class="flex flex-col min-w-[280px] max-w-[320px] w-full">
      <div class="flex items-center justify-between mb-3 px-1">
        <div class="flex items-center gap-2">
          <h3 class="text-xs font-medium text-base-content/50 uppercase">
            {column_label(@column)}
          </h3>
          <span class="badge badge-sm badge-ghost">{length(@cards)}</span>
        </div>
      </div>

      <div
        id={@id}
        phx-hook={if @sortable, do: "Sortable"}
        data-column={@column}
        class="flex flex-col gap-2 min-h-[200px] p-2 bg-base-200/50 rounded-xl"
      >
        <.board_card :for={card <- @cards} card={card} />
        <div
          :if={@cards == []}
          class="flex items-center justify-center h-24 text-base-content/30 text-sm"
        >
          No prompts yet
        </div>
      </div>
    </div>
    """
  end

  attr :card, :map, required: true

  def board_card(assigns) do
    ~H"""
    <.link
      navigate={"/prompts/#{@card.id}"}
      data-id={@card.id}
      class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow cursor-pointer"
    >
      <div class="card-body p-4 gap-2">
        <h4 class={[
          "text-sm font-medium leading-tight",
          @card[:title_generating] && "animate-pulse text-base-content/50"
        ]}>
          {@card.title}
        </h4>

        <div class="flex items-center justify-between gap-2">
          <.workflow_badge type={@card.workflow_type} />
          <span class="text-xs text-base-content/40">
            {@card.steps_completed}/{@card.steps_total}
          </span>
        </div>

        <.progress_indicator
          completed={@card.steps_completed}
          total={@card.steps_total}
        />
      </div>
    </.link>
    """
  end

  attr :type, :atom, required: true

  def workflow_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm font-medium",
      workflow_badge_class(@type)
    ]}>
      {workflow_label(@type)}
    </span>
    """
  end

  attr :completed, :integer, required: true
  attr :total, :integer, required: true

  def progress_indicator(assigns) do
    assigns = assign(assigns, :percentage, floor(assigns.completed / max(assigns.total, 1) * 100))

    ~H"""
    <div class="h-1 bg-base-300 rounded-full overflow-hidden">
      <div
        class={[
          "h-full rounded-full transition-all",
          if(@percentage == 100, do: "bg-success", else: "bg-primary")
        ]}
        style={"width: #{@percentage}%"}
      />
    </div>
    """
  end

  # Helpers

  defp column_label(:request), do: "Request"
  defp column_label(:distill), do: "Distill"
  defp column_label(:done), do: "Done"
  defp column_label(:todo), do: "Todo"
  defp column_label(:in_progress), do: "In Progress"
  defp column_label(:review), do: "Review"
  defp column_label(:qa), do: "QA"
  defp column_label(:impl_done), do: "Done"

  defp workflow_label(:feature_request), do: "Feature Request"
  defp workflow_label(:project), do: "Project"

  defp workflow_badge_class(:feature_request), do: "badge-info"
  defp workflow_badge_class(:project), do: "badge-secondary"
end
