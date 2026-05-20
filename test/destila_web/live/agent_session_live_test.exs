defmodule DestilaWeb.AgentSessionLiveTest do
  use DestilaWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Destila.Agent.Sessions
  alias Destila.Test.MockMCPClient

  @tag feature: "mcp_driven_session", scenario: "Session is created without a chat textarea"
  test "renders without any chat textarea", %{conn: conn} do
    {:ok, session} = Sessions.create_session(embedded_attrs())
    {:ok, view, _html} = live(conn, ~p"/agent-sessions/#{session.id}")

    refute has_element?(view, "textarea[name='chat']")
    refute has_element?(view, "#chat-form")
  end

  @tag feature: "mcp_driven_session",
       scenario: "Empty session shows an exports placeholder, not a chat transcript"
  test "renders the exports placeholder on an empty session", %{conn: conn} do
    {:ok, session} = Sessions.create_session(embedded_attrs())
    {:ok, view, _html} = live(conn, ~p"/agent-sessions/#{session.id}")

    assert has_element?(view, "#exports-empty-placeholder")
    assert has_element?(view, "#exports-panel")
    assert has_element?(view, "#event-log-panel")
  end

  @tag feature: "mcp_driven_session",
       scenario: "Session detail page is reachable while the agent is disconnected"
  test "session page mounts with not-connected indicator before the agent arrives", %{conn: conn} do
    {:ok, session} = Sessions.create_session(external_attrs())
    {:ok, view, _html} = live(conn, ~p"/agent-sessions/#{session.id}")

    assert has_element?(view, "#agent-status")
  end

  @tag feature: "mcp_driven_session",
       scenario: "New exports appear in real-time at the top of the session view"
  test "real-time export render", %{conn: conn} do
    {:ok, session} = Sessions.create_session(embedded_attrs())
    {:ok, view, _html} = live(conn, ~p"/agent-sessions/#{session.id}")

    {:ok, _} = MockMCPClient.simulate_export(session.id, "prompt", "hi")

    render(view)
    assert render(view) =~ "prompt"
  end

  @tag feature: "mcp_driven_session",
       scenario: "User types directly into the embedded terminal"
  test "embedded sessions render the xterm.js terminal panel", %{conn: conn} do
    {:ok, session} = Sessions.create_session(embedded_attrs())
    {:ok, view, _html} = live(conn, ~p"/agent-sessions/#{session.id}")

    assert has_element?(view, "#embedded-terminal")
    refute has_element?(view, "#external-host-panel")
  end

  @tag feature: "mcp_driven_session",
       scenario: "Creating an external-host session shows MCP connection instructions"
  test "external sessions render the connection-info panel", %{conn: conn} do
    {:ok, session} = Sessions.create_session(external_attrs())
    {:ok, view, _html} = live(conn, ~p"/agent-sessions/#{session.id}")

    assert has_element?(view, "#external-host-panel")
    assert has_element?(view, "#external-mcp-url")
    assert has_element?(view, "#external-token")
    refute has_element?(view, "#embedded-terminal")
  end

  defp embedded_attrs do
    %{workflow_name: "example", host_mode: :embedded, total_phases: 2}
  end

  defp external_attrs do
    %{workflow_name: "example", host_mode: :external, total_phases: 1}
  end
end
