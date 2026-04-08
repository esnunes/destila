defmodule DestilaWeb.BoardComponents do
  use Phoenix.Component

  alias Destila.Workflows.Session

  attr :type, :atom, required: true

  def workflow_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm font-medium whitespace-nowrap",
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

  attr :session, :map, required: true
  attr :alive?, :boolean, required: true
  attr :phase_status, :atom, default: nil

  def aliveness_dot(assigns) do
    phase_status = assigns[:phase_status] || Session.phase_status(assigns.session)
    assigns = assign(assigns, :aliveness_state, aliveness_state(phase_status, assigns.alive?))

    ~H"""
    <span
      title={aliveness_title(@aliveness_state)}
      class={["inline-flex size-2 shrink-0 rounded-full", aliveness_color(@aliveness_state)]}
    />
    """
  end

  defp aliveness_state(_phase_status, true), do: :alive

  defp aliveness_state(phase_status, false) do
    if should_be_alive?(phase_status), do: :unexpected_down, else: :expected_down
  end

  @doc """
  Returns true if the session is in a state where a ClaudeSession GenServer should be running.
  """
  def should_be_alive?(phase_status) when is_atom(phase_status), do: phase_status == :processing

  defp aliveness_color(:alive), do: "bg-success"
  defp aliveness_color(:expected_down), do: "bg-base-content/20"
  defp aliveness_color(:unexpected_down), do: "bg-error animate-pulse"

  defp aliveness_title(:alive), do: "AI session running"
  defp aliveness_title(:expected_down), do: "AI session idle"
  defp aliveness_title(:unexpected_down), do: "AI session not running (unexpected)"

  attr :card, :map, required: true
  attr :project_filter, :string, default: nil
  attr :compact, :boolean, default: false
  attr :alive?, :boolean, default: false

  def crafting_card(assigns) do
    card_phase_status = Session.phase_status(assigns.card)
    assigns = assign(assigns, :card_phase_status, card_phase_status)

    ~H"""
    <div
      id={"crafting-card-#{@card.id}"}
      class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow"
    >
      <div class={["card-body gap-2", if(@compact, do: "p-3", else: "p-4")]}>
        <div class={["flex gap-2", if(@compact, do: "items-start", else: "items-center")]}>
          <.aliveness_dot session={@card} alive?={@alive?} phase_status={@card_phase_status} />
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
          <div :if={@compact} class="flex items-center gap-1 shrink-0">
            <.status_dot card={@card} phase_status={@card_phase_status} />
          </div>
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
          :if={!@compact && @card.total_phases > 1}
          completed={@card.current_phase}
          total={@card.total_phases}
        />
      </div>
    </div>
    """
  end

  attr :card, :map, required: true
  attr :phase_status, :atom, default: nil

  defp status_dot(assigns) do
    {color, title} = status_dot_style(assigns.card, assigns.phase_status)
    assigns = assigns |> assign(:dot_color, color) |> assign(:dot_title, title)

    ~H"""
    <span title={@dot_title} class={["inline-flex size-2 shrink-0 rounded-full", @dot_color]} />
    """
  end

  defp status_dot_style(card, phase_status) do
    cond do
      Session.done?(card) ->
        {"bg-success", "Done"}

      phase_status in [:awaiting_input, :awaiting_confirmation] ->
        {"bg-warning", "Waiting for you"}

      phase_status == :processing ->
        {"bg-info animate-pulse", "AI is responding"}

      true ->
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

  def workflow_label(:brainstorm_idea), do: "Brainstorm Idea"
  def workflow_label(:implement_general_prompt), do: "Implementation"
  def workflow_label(:code_chat), do: "Code Chat"
  def workflow_label(_), do: "Workflow"

  defp workflow_badge_class(:brainstorm_idea), do: "bg-amber-600 text-white"
  defp workflow_badge_class(:implement_general_prompt), do: "badge-primary"
  defp workflow_badge_class(:code_chat), do: "badge-accent"
  defp workflow_badge_class(_), do: "badge-neutral"
end
