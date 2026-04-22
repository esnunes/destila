defmodule DestilaWeb.FollowUpModalComponent do
  @moduledoc """
  Post-completion follow-up modal. Offers to start a compatible follow-up
  workflow and archive the current session, archive without starting, or
  dismiss.

  Receives `:open?` and `:candidates` from the parent LiveView and forwards
  user intent back via `send(self(), ...)`:

    * `:close_follow_up_modal`
    * `:archive_only`
    * `{:start_follow_up, workflow_type}`

  Candidates are `{workflow_type, label, source_metadata_key}` tuples as
  returned by `Destila.Workflows.list_follow_up_workflows/1`.
  """

  use DestilaWeb, :live_component

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:open?, assigns[:open?] || false)
     |> assign(:candidates, assigns[:candidates] || [])}
  end

  def handle_event("close_follow_up_modal", _params, socket) do
    send(self(), :close_follow_up_modal)
    {:noreply, socket}
  end

  def handle_event("archive_only", _params, socket) do
    send(self(), :archive_only)
    {:noreply, socket}
  end

  def handle_event("start_follow_up", %{"workflow_type" => type_str}, socket) do
    workflow_type = String.to_existing_atom(type_str)
    send(self(), {:start_follow_up, workflow_type})
    {:noreply, socket}
  end

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
          <div class="relative z-10 w-full max-w-lg mx-4">
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

              <div class="px-5 py-4 space-y-2">
                <%= if @candidates == [] do %>
                  <p
                    id="follow-up-modal-empty-state"
                    class="text-sm text-base-content/50 py-2"
                  >
                    No follow-up workflows are available for this session.
                  </p>
                <% else %>
                  <div class="space-y-2">
                    <button
                      :for={{type, label, _key} <- @candidates}
                      id={"follow-up-start-#{type}-btn"}
                      phx-click="start_follow_up"
                      phx-target={@myself}
                      phx-value-workflow_type={type}
                      class="btn btn-primary btn-block justify-start"
                    >
                      <.icon name="hero-rocket-launch-micro" class="size-4" />
                      Start {label} and archive
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
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
