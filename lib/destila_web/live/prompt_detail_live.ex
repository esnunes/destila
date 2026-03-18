defmodule DestilaWeb.PromptDetailLive do
  use DestilaWeb, :live_view

  def mount(%{"id" => id}, session, socket) do
    {:ok,
     socket
     |> assign(:current_user, session["current_user"])
     |> assign(:prompt_id, id)
     |> assign(:page_title, "Prompt Detail")}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="p-8">
        <h1 class="text-2xl font-bold mb-6">Prompt Detail</h1>
        <p class="text-base-content/60">Chat workflow coming soon...</p>
      </div>
    </Layouts.app>
    """
  end
end
