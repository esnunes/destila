defmodule DestilaWeb.Phases.SetupPhase do
  @moduledoc """
  LiveComponent for Phase 2 — displays setup progress (title generation,
  repo sync, worktree creation) and auto-advances when all steps complete.

  Receives metadata from the parent LiveView via the `metadata` assign.
  """

  use DestilaWeb, :live_component

  def update(assigns, socket) do
    ws = assigns.workflow_session
    workflow = assigns.workflow
    metadata = assigns[:metadata] || %{}
    steps = build_steps(ws, metadata)

    if connected?(socket) && ws do
      workflow.initiate_setup(ws, metadata)
    end

    if all_completed?(steps) do
      send(self(), {:phase_complete, assigns.phase_number, %{}})
    end

    {:ok,
     socket
     |> assign(:workflow_session, ws)
     |> assign(:workflow, workflow)
     |> assign(:phase_number, assigns.phase_number)
     |> assign(:steps, steps)
     |> assign(:all_done, all_completed?(steps))
     |> assign(:has_failure, has_failure?(steps))}
  end

  def handle_event("retry_setup", _params, socket) do
    socket.assigns.workflow.retry_setup(socket.assigns.workflow_session)
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="overflow-y-auto h-full px-6 py-6">
      <div class="max-w-2xl mx-auto space-y-2">
        <.step_item :for={step <- @steps} step={step} myself={@myself} />
      </div>
    </div>
    """
  end

  defp step_item(assigns) do
    ~H"""
    <div class="flex items-center gap-3 text-sm pl-2">
      <%= case @step.status do %>
        <% "completed" -> %>
          <.icon name="hero-check-circle-solid" class="size-4 text-success shrink-0" />
        <% "in_progress" -> %>
          <span class="loading loading-spinner loading-xs shrink-0" />
        <% "failed" -> %>
          <.icon name="hero-x-circle-solid" class="size-4 text-error shrink-0" />
        <% _ -> %>
          <span class="size-4 rounded-full border-2 border-base-300 shrink-0" />
      <% end %>
      <span class={[
        "flex-1",
        @step.status == "completed" && "text-base-content/60",
        @step.status == "in_progress" && "text-base-content/80",
        @step.status == "failed" && "text-error"
      ]}>
        {@step.label}
        <span :if={@step.error} class="text-xs ml-1">— {@step.error}</span>
      </span>
      <button
        :if={@step.status == "failed"}
        phx-click="retry_setup"
        phx-target={@myself}
        class="btn btn-xs btn-outline btn-error"
      >
        Retry
      </button>
    </div>
    """
  end

  defp build_steps(ws, metadata) do
    title_step = %{
      key: "title_gen",
      label: step_label("title_gen", metadata),
      status: get_step_status(metadata, "title_gen"),
      error: get_step_error(metadata, "title_gen")
    }

    if ws.project_id do
      project = Destila.Projects.get_project(ws.project_id)

      repo_label =
        if project && project.local_folder && project.local_folder != "",
          do: "Pulling latest changes...",
          else: "Syncing repository..."

      [
        title_step,
        %{
          key: "repo_sync",
          label: repo_label,
          status: get_step_status(metadata, "repo_sync"),
          error: get_step_error(metadata, "repo_sync")
        },
        %{
          key: "worktree",
          label: "Creating worktree...",
          status: get_step_status(metadata, "worktree"),
          error: get_step_error(metadata, "worktree")
        }
      ]
    else
      [title_step]
    end
  end

  defp step_label("title_gen", _), do: "Generating title..."
  defp step_label(_, _), do: ""

  defp get_step_status(metadata, key) do
    case metadata[key] do
      %{"status" => status} -> status
      _ -> "pending"
    end
  end

  defp get_step_error(metadata, key) do
    case metadata[key] do
      %{"error" => error} -> error
      _ -> nil
    end
  end

  defp all_completed?(steps) do
    Enum.all?(steps, &(&1.status == "completed"))
  end

  defp has_failure?(steps) do
    Enum.any?(steps, &(&1.status == "failed"))
  end
end
