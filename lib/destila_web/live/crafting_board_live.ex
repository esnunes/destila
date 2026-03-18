defmodule DestilaWeb.CraftingBoardLive do
  use DestilaWeb, :live_view

  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:current_user, session["current_user"])
     |> assign(:page_title, "Prompt Crafting")}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="p-8">
        <h1 class="text-2xl font-bold mb-6">Prompt Crafting Board</h1>
        <p class="text-base-content/60">Board coming soon...</p>
      </div>
    </Layouts.app>
    """
  end
end
