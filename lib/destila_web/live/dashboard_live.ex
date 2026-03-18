defmodule DestilaWeb.DashboardLive do
  use DestilaWeb, :live_view

  def mount(_params, session, socket) do
    current_user = session["current_user"]

    {:ok,
     socket
     |> assign(:current_user, current_user)
     |> assign(:page_title, "Dashboard")}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="p-8">
        <h1 class="text-2xl font-bold mb-6">Welcome back, {@current_user.name}</h1>
        <p class="text-base-content/60">Dashboard coming soon...</p>
      </div>
    </Layouts.app>
    """
  end
end
