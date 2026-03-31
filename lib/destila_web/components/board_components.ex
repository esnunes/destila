defmodule DestilaWeb.BoardComponents do
  use Phoenix.Component

  alias Destila.Workflows.Session

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

  attr :card, :map, required: true
  attr :project_filter, :string, default: nil
  attr :compact, :boolean, default: false

  def crafting_card(assigns) do
    ~H"""
    <div
      id={"crafting-card-#{@card.id}"}
      class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow"
    >
      <div class={["card-body gap-2", if(@compact, do: "p-3", else: "p-4")]}>
        <div class={["flex gap-2", if(@compact, do: "items-start", else: "items-center")]}>
          <.link
            navigate={"/sessions/#{@card.id}"}
            class={[
              "text-sm font-medium leading-tight hover:text-primary transition-colors flex-1 min-w-0",
              if(@compact, do: "line-clamp-3", else: "truncate")
            ]}
          >
            <span class={[
              @card.title_generating && "animate-pulse text-base-content/50"
            ]}>
              {@card.title}
            </span>
          </.link>
          <.status_dot :if={@compact} card={@card} />
        </div>

        <%= if @compact do %>
          <span :if={@card.project} class="text-xs text-base-content/50 truncate">
            {@card.project.name}
          </span>
        <% else %>
          <div class="flex items-center justify-between gap-2">
            <div class="flex items-center gap-2">
              <.workflow_badge type={@card.workflow_type} />
              <%= if @card.project do %>
                <.link
                  patch={
                    if @project_filter == @card.project_id,
                      do: "/crafting",
                      else: "/crafting?project=#{@card.project_id}"
                  }
                  class="text-xs text-base-content/60 hover:text-primary transition-colors truncate max-w-[120px]"
                >
                  {@card.project.name}
                </.link>
              <% end %>
            </div>
            <span class="text-xs text-base-content/40 whitespace-nowrap">
              {phase_label(@card)}
            </span>
          </div>
        <% end %>

        <.progress_indicator
          :if={!@compact}
          completed={@card.current_phase}
          total={@card.total_phases}
        />
      </div>
    </div>
    """
  end

  attr :card, :map, required: true

  defp status_dot(assigns) do
    {color, title} = status_dot_style(assigns.card)
    assigns = assigns |> assign(:dot_color, color) |> assign(:dot_title, title)

    ~H"""
    <span title={@dot_title} class={["inline-flex size-2 shrink-0 rounded-full", @dot_color]} />
    """
  end

  defp status_dot_style(%{phase_status: s}) when s in [:conversing, :advance_suggested],
    do: {"bg-warning", "Waiting for you"}

  defp status_dot_style(%{phase_status: :processing}),
    do: {"bg-info animate-pulse", "AI is responding"}

  defp status_dot_style(%{phase_status: :setup}),
    do: {"bg-base-content/20", "Setting up"}

  defp status_dot_style(card) do
    if Session.done?(card) do
      {"bg-success", "Done"}
    else
      {"bg-primary/40", "In progress"}
    end
  end

  defp phase_label(card) do
    if Session.done?(card) do
      "Done"
    else
      Destila.Workflows.phase_name(card.workflow_type, card.current_phase) ||
        "Phase #{card.current_phase}"
    end
  end

  # Helpers

  def workflow_label(:prompt_chore_task), do: "Chore/Task"
  def workflow_label(:implement_general_prompt), do: "Implementation"
  def workflow_label(_), do: "Workflow"

  defp workflow_badge_class(:prompt_chore_task), do: "badge-warning"
  defp workflow_badge_class(:implement_general_prompt), do: "badge-primary"
  defp workflow_badge_class(_), do: "badge-neutral"
end
