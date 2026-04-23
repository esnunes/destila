defmodule DestilaWeb.FollowUpModalComponent do
  @moduledoc """
  Post-completion follow-up modal. Shows each compatible follow-up workflow as
  a selectable card (icon, label, description). Actions in the modal footer
  operate on the selected card:

    * `Start and archive` — primary action (start the follow-up and archive the
      source session)
    * `Start` — start the follow-up without archiving the source
    * `Archive only` — archive the source without starting a follow-up
    * `Close` — dismiss the modal

  Receives `:open?` and `:candidates` from the parent LiveView and forwards
  user intent back via `send(self(), ...)`:

    * `:close_follow_up_modal`
    * `:archive_only`
    * `{:start_follow_up, workflow_type, archive_source?}`

  Each candidate is a map with `:type`, `:label`, `:description`, `:icon`,
  `:icon_class`, and `:source_metadata_key` as returned by
  `Destila.Workflows.list_follow_up_workflows/1`.
  """

  use DestilaWeb, :live_component

  def update(assigns, socket) do
    previous_open? = socket.assigns[:open?] || false
    new_open? = assigns[:open?] || false

    selected =
      if new_open? and not previous_open? do
        default_selection(assigns[:candidates] || [])
      else
        socket.assigns[:selected_type]
      end

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:open?, new_open?)
     |> assign(:candidates, assigns[:candidates] || [])
     |> assign(:selected_type, selected)}
  end

  def handle_event("close_follow_up_modal", _params, socket) do
    send(self(), :close_follow_up_modal)
    {:noreply, socket}
  end

  def handle_event("archive_only", _params, socket) do
    send(self(), :archive_only)
    {:noreply, socket}
  end

  def handle_event("select_workflow", %{"workflow_type" => type_str}, socket) do
    workflow_type = String.to_existing_atom(type_str)
    {:noreply, assign(socket, :selected_type, workflow_type)}
  end

  def handle_event("start_follow_up", %{"archive" => archive_str}, socket) do
    case socket.assigns.selected_type do
      nil ->
        {:noreply, socket}

      workflow_type ->
        archive? = archive_str == "true"
        send(self(), {:start_follow_up, workflow_type, archive?})
        {:noreply, socket}
    end
  end

  defp default_selection([%{type: type} | _]), do: type
  defp default_selection(_), do: nil

  def render(assigns) do
    ~H"""
    <div id={@id}>
      <%= if @open? do %>
        <div
          id="follow-up-modal"
          class="fixed inset-0 z-50 flex items-center justify-center"
        >
          <div
            class="absolute inset-0 bg-black/70 backdrop-blur-sm"
            phx-click="close_follow_up_modal"
            phx-target={@myself}
          />
          <div class="relative z-10 w-full max-w-xl mx-4">
            <button
              id="follow-up-modal-close-x"
              phx-click="close_follow_up_modal"
              phx-target={@myself}
              class="absolute -top-10 right-0 text-white/70 hover:text-white transition-colors"
              aria-label="Close"
            >
              <.icon name="hero-x-mark" class="size-6" />
            </button>
            <div class="rounded-xl bg-base-100 shadow-2xl overflow-hidden">
              <div class="px-5 py-4 border-b border-base-300/60">
                <h2 class="text-base font-semibold text-base-content">
                  Workflow complete — what's next?
                </h2>
                <p class="text-xs text-base-content/50 mt-0.5">
                  Pick a follow-up, archive the session, or close this dialog.
                </p>
              </div>

              <div class="px-5 py-4 max-h-[60vh] overflow-y-auto">
                <%= if @candidates == [] do %>
                  <p
                    id="follow-up-modal-empty-state"
                    class="text-sm text-base-content/50 py-2"
                  >
                    No follow-up workflows are available for this session.
                  </p>
                <% else %>
                  <div class="grid gap-3">
                    <button
                      :for={wf <- @candidates}
                      type="button"
                      id={"follow-up-card-#{wf.type}"}
                      phx-click="select_workflow"
                      phx-target={@myself}
                      phx-value-workflow_type={wf.type}
                      aria-pressed={to_string(@selected_type == wf.type)}
                      class={[
                        "card bg-base-100 border-2 text-left transition-all cursor-pointer",
                        if(@selected_type == wf.type,
                          do: "border-primary ring-2 ring-primary/30 bg-primary/5",
                          else: "border-base-300 hover:border-primary/60"
                        )
                      ]}
                    >
                      <div class="card-body p-4">
                        <div class="flex items-start gap-3">
                          <.icon name={wf.icon} class={["size-8 shrink-0", wf.icon_class]} />
                          <div class="flex-1 min-w-0">
                            <div class="flex items-center justify-between gap-2">
                              <h3 class="font-semibold text-sm text-base-content">{wf.label}</h3>
                              <span
                                :if={@selected_type == wf.type}
                                class="inline-flex items-center gap-1 text-[10px] font-medium uppercase tracking-wider text-primary shrink-0"
                              >
                                <.icon name="hero-check-circle-micro" class="size-3.5" /> Selected
                              </span>
                            </div>
                            <p class="text-xs text-base-content/60 mt-0.5">{wf.description}</p>
                          </div>
                        </div>
                      </div>
                    </button>
                  </div>
                <% end %>
              </div>

              <div class="px-5 py-4 border-t border-base-300/60 flex items-center justify-end gap-2">
                <button
                  id="follow-up-close-btn"
                  phx-click="close_follow_up_modal"
                  phx-target={@myself}
                  class="btn btn-ghost btn-sm"
                >
                  Close
                </button>
                <button
                  id="follow-up-archive-only-btn"
                  phx-click="archive_only"
                  phx-target={@myself}
                  class="btn btn-soft btn-sm"
                >
                  <.icon name="hero-archive-box-micro" class="size-4" /> Archive only
                </button>
                <button
                  :if={@candidates != []}
                  id="follow-up-start-btn"
                  phx-click="start_follow_up"
                  phx-target={@myself}
                  phx-value-archive="false"
                  disabled={is_nil(@selected_type)}
                  class="btn btn-soft btn-sm"
                >
                  <.icon name="hero-rocket-launch-micro" class="size-4" /> Start
                </button>
                <button
                  :if={@candidates != []}
                  id="follow-up-start-and-archive-btn"
                  phx-click="start_follow_up"
                  phx-target={@myself}
                  phx-value-archive="true"
                  disabled={is_nil(@selected_type)}
                  class="btn btn-primary btn-sm"
                >
                  <.icon name="hero-rocket-launch-micro" class="size-4" /> Start and archive
                </button>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
