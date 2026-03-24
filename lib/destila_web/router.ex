defmodule DestilaWeb.Router do
  use DestilaWeb, :router

  import Oban.Web.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DestilaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :require_auth do
    plug DestilaWeb.Plugs.RequireAuth
  end

  # Public routes (no auth required)
  scope "/", DestilaWeb do
    pipe_through :browser

    live "/login", SessionLive
    post "/login", SessionController, :create
    get "/logout", SessionController, :delete
  end

  # Oban Web dashboard
  scope "/" do
    pipe_through [:browser, :require_auth]

    oban_dashboard("/oban")
  end

  # Authenticated routes
  scope "/", DestilaWeb do
    pipe_through [:browser, :require_auth]

    live "/", DashboardLive
    live "/crafting", CraftingBoardLive
    live "/projects", ProjectsLive
    live "/sessions/new", NewSessionLive
    live "/sessions/:id", SessionDetailLive
  end
end
