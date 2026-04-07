defmodule DestilaWeb.SetupComponents do
  @moduledoc """
  Function component for setup status — displays setup progress (repo sync,
  worktree creation). Rendered by WorkflowRunnerLive when no phase execution
  exists yet (derived status is `:setup`).
  """

  use DestilaWeb, :html

  attr :workflow_session, :map, required: true
  attr :metadata, :map, required: true

  def setup(assigns) do
    ws = assigns.workflow_session
    metadata = assigns.metadata
    steps = build_steps(ws, metadata)

    assigns = assign(assigns, :steps, steps)

    ~H"""
    <div class="overflow-y-auto h-full px-6 py-6">
      <div class="max-w-2xl mx-auto space-y-2">
        <.step_item :for={step <- @steps} step={step} />
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
        class="btn btn-xs btn-outline btn-error"
      >
        Retry
      </button>
    </div>
    """
  end

  defp build_steps(ws, metadata) do
    if ws.project_id do
      [
        %{
          key: "repo_sync",
          label: "Syncing repository...",
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
      []
    end
  end

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
end
