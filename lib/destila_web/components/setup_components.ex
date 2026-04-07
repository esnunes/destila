defmodule DestilaWeb.SetupComponents do
  @moduledoc """
  Function component for setup status — displays a simple preparing indicator.
  Rendered by WorkflowRunnerLive when no phase execution exists yet (defensive).
  """

  use DestilaWeb, :html

  attr :workflow_session, :map, required: true

  def setup(assigns) do
    ~H"""
    <div class="overflow-y-auto h-full px-6 py-6">
      <div class="max-w-2xl mx-auto">
        <div class="flex items-center gap-3 text-sm pl-2">
          <span class="loading loading-spinner loading-xs shrink-0" />
          <span class="text-base-content/80">Preparing workspace...</span>
        </div>
      </div>
    </div>
    """
  end
end
