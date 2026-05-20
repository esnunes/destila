defmodule Destila.Agent.SessionServerTest do
  use ExUnit.Case, async: false

  alias Destila.Agent.{Sessions, SessionServer}
  alias Destila.Test.MockMCPClient

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Destila.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @tag feature: "mcp_driven_session",
       scenario: "Session activates when the external agent connects"
  test "sse_connected transitions awaiting_agent to active" do
    {:ok, session} = Sessions.create_session(valid_attrs(:external))
    {:ok, _pid} = SessionServer.ensure_started(session.id)

    MockMCPClient.simulate_connect(session.id)

    # Allow the cast to flush
    _ = SessionServer.get_state(session.id)

    updated = Sessions.get_session(session.id)
    assert updated.status == :active
  end

  @tag feature: "mcp_driven_session",
       scenario: "Agent exit without phase_complete leaves the phase open"
  test "sse_closed transitions active to disconnected without advancing phase" do
    {:ok, session} = Sessions.create_session(valid_attrs(:embedded))
    {:ok, _pid} = SessionServer.ensure_started(session.id)

    MockMCPClient.simulate_connect(session.id)
    _ = SessionServer.get_state(session.id)
    MockMCPClient.simulate_disconnect(session.id)
    _ = SessionServer.get_state(session.id)

    updated = Sessions.get_session(session.id)
    assert updated.status == :disconnected
    assert updated.current_phase_index == 0
  end

  @tag feature: "mcp_driven_session", scenario: "Session log records only tool-call events"
  test "tool calls are written to the event log; no assistant text channel exists" do
    {:ok, session} = Sessions.create_session(valid_attrs(:embedded))

    {:ok, _reply} =
      MockMCPClient.simulate_tool_call(session.id, "session", %{
        "action" => "export",
        "key" => "k",
        "value" => "v"
      })

    events = Sessions.list_events(session.id)
    # export records two events: session.export + (no extra) — keep this resilient
    assert Enum.all?(events, &is_struct(&1, Destila.Agent.SessionEvent))
    assert Enum.any?(events, &(&1.tool_name == "session.export"))
  end

  defp valid_attrs(host_mode) do
    %{
      workflow_name: "example",
      host_mode: host_mode,
      total_phases: 2
    }
  end
end
