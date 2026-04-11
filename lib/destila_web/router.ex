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

  scope "/" do
    pipe_through :browser

    oban_dashboard("/oban")
  end

  scope "/", DestilaWeb do
    pipe_through :browser

    live "/", DashboardLive
    live "/crafting", CraftingBoardLive
    live "/projects", ProjectsLive
    live "/workflows", CreateSessionLive
    live "/workflows/:workflow_type", CreateSessionLive
    live "/sessions/archived", ArchivedSessionsLive
    get "/media/:id", MediaController, :show
    live "/sessions/:id/terminal", TerminalLive
    live "/sessions/:id", WorkflowRunnerLive
  end
end
