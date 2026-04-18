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

  pipeline :session_detail do
    plug :put_session_detail_referer
  end

  defp put_session_detail_referer(conn, _opts) do
    case Plug.Conn.get_req_header(conn, "referer") do
      [referer | _] when is_binary(referer) and referer != "" ->
        Plug.Conn.put_session(conn, :session_detail_referer, referer)

      _ ->
        conn
    end
  end

  scope "/" do
    pipe_through :browser

    oban_dashboard("/oban")
  end

  scope "/", DestilaWeb do
    pipe_through :browser

    live "/", DashboardLive
    live "/crafting", CraftingBoardLive
    live "/projects/archived", ArchivedProjectsLive
    live "/projects", ProjectsLive
    live "/workflows", CreateSessionLive
    live "/workflows/:workflow_type", CreateSessionLive
    live "/sessions/archived", ArchivedSessionsLive
    get "/media/:id", MediaController, :show
    live "/sessions/:id/terminal", TerminalLive
    live "/sessions/:workflow_session_id/ai/:ai_session_id", AiSessionDetailLive
  end

  scope "/", DestilaWeb do
    pipe_through [:browser, :session_detail]

    live "/sessions/:id", WorkflowRunnerLive
  end
end
