defmodule DestilaWeb.AgentSessionCreateLiveTest do
  use DestilaWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Destila.Agent.{Sessions, WorkflowLoader}

  setup do
    :ok = WorkflowLoader.load_all()
    :ok
  end

  @tag feature: "mcp_driven_session", scenario: "Session is created without a chat textarea"
  test "creates an embedded agent session and redirects", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agent-sessions/new")

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> form("#agent-session-form", %{
               "agent_session" => %{
                 "workflow_name" => "example",
                 "host_mode" => "embedded",
                 "project_id" => ""
               }
             })
             |> render_submit()

    assert to =~ "/agent-sessions/"

    [session] = Sessions.list_sessions()
    assert session.workflow_name == "example"
    assert session.host_mode == :embedded
  end

  test "creates an external agent session", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agent-sessions/new")

    assert {:error, {:live_redirect, _}} =
             view
             |> form("#agent-session-form", %{
               "agent_session" => %{
                 "workflow_name" => "example",
                 "host_mode" => "external",
                 "project_id" => ""
               }
             })
             |> render_submit()

    [session] = Sessions.list_sessions()
    assert session.host_mode == :external
  end

  test "shows error when no workflow is selected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agent-sessions/new")

    html =
      view
      |> form("#agent-session-form", %{
        "agent_session" => %{
          "workflow_name" => "",
          "host_mode" => "embedded",
          "project_id" => ""
        }
      })
      |> render_submit()

    assert html =~ "Please choose a workflow"
  end
end
