defmodule DestilaWeb.Phases.SetupPhase do
  @moduledoc """
  LiveComponent for Phase 2 — displays setup progress (title generation,
  repo sync, worktree creation) and auto-advances when all steps complete.

  Subscribes to PubSub directly to receive real-time setup_steps updates.
  """

  use DestilaWeb, :live_component

  def mount(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
    end

    {:ok, assign(socket, :initialized, false)}
  end

  def update(assigns, socket) do
    ws = assigns.workflow_session
    steps = build_steps(ws)

    socket =
      socket
      |> assign(:workflow_session, ws)
      |> assign(:phase_number, assigns.phase_number)
      |> assign(:steps, steps)
      |> assign(:all_done, all_completed?(steps))
      |> assign(:has_failure, has_failure?(steps))

    # On first mount, set phase_status and enqueue workers if not already running
    socket =
      if !socket.assigns.initialized && connected?(socket) && ws do
        maybe_start_setup(ws)
        assign(socket, :initialized, true)
      else
        socket
      end

    {:ok, socket}
  end

  # PubSub: workflow session updated — refresh setup_steps
  def handle_info({:workflow_session_updated, updated_ws}, socket) do
    if updated_ws.id == socket.assigns.workflow_session.id do
      ws = Destila.WorkflowSessions.get_workflow_session!(updated_ws.id)
      steps = build_steps(ws)

      socket =
        socket
        |> assign(:workflow_session, ws)
        |> assign(:steps, steps)
        |> assign(:all_done, all_completed?(steps))
        |> assign(:has_failure, has_failure?(steps))

      # Signal parent when setup advances to next phase
      if ws.current_phase > socket.assigns.phase_number do
        send(self(), {:phase_complete, socket.assigns.phase_number, %{}})
      end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  def handle_event("retry_setup", _params, socket) do
    ws = socket.assigns.workflow_session

    if ws.project_id do
      %{"workflow_session_id" => ws.id}
      |> Destila.Workers.SetupWorker.new()
      |> Oban.insert()
    end

    if ws.title_generating do
      %{"workflow_session_id" => ws.id, "idea" => ""}
      |> Destila.Workers.TitleGenerationWorker.new()
      |> Oban.insert()
    end

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="overflow-y-auto h-full px-6 py-6">
      <div class="max-w-2xl mx-auto space-y-2">
        <.step_item :for={step <- @steps} step={step} myself={@myself} />

        <div
          :if={!@all_done && !@has_failure}
          class="flex items-center gap-3 text-sm text-base-content/50 pl-2"
        >
          <span class="loading loading-spinner loading-xs" />
          <span>Setting up...</span>
        </div>
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

  defp maybe_start_setup(ws) do
    # Only start if no steps are in progress or completed yet
    setup_steps = ws.setup_steps || %{}
    has_progress = Enum.any?(setup_steps, fn {k, _v} -> k != "idea" end)

    unless has_progress do
      Destila.WorkflowSessions.update_workflow_session(ws, %{phase_status: :setup})

      idea = setup_steps["idea"] || ""

      %{"workflow_session_id" => ws.id, "idea" => idea}
      |> Destila.Workers.TitleGenerationWorker.new()
      |> Oban.insert()

      if ws.project_id do
        %{"workflow_session_id" => ws.id}
        |> Destila.Workers.SetupWorker.new()
        |> Oban.insert()
      end
    end
  end

  # Build the step list based on workflow session state
  defp build_steps(ws) do
    setup_steps = ws.setup_steps || %{}

    title_step = %{
      key: "title_gen",
      label: step_label("title_gen", setup_steps),
      status: get_step_status(setup_steps, "title_gen"),
      error: get_step_error(setup_steps, "title_gen")
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
          status: get_step_status(setup_steps, "repo_sync"),
          error: get_step_error(setup_steps, "repo_sync")
        },
        %{
          key: "worktree",
          label: "Creating worktree...",
          status: get_step_status(setup_steps, "worktree"),
          error: get_step_error(setup_steps, "worktree")
        }
      ]
    else
      [title_step]
    end
  end

  defp step_label("title_gen", _), do: "Generating title..."
  defp step_label(_, _), do: ""

  defp get_step_status(setup_steps, key) do
    case setup_steps[key] do
      %{"status" => status} -> status
      _ -> "pending"
    end
  end

  defp get_step_error(setup_steps, key) do
    case setup_steps[key] do
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
