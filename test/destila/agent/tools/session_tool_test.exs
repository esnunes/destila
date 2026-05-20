defmodule Destila.Agent.Tools.SessionToolTest do
  use ExUnit.Case, async: false

  alias Destila.Agent.Sessions
  alias Destila.Test.MockMCPClient

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Destila.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @tag feature: "mcp_driven_session", scenario: "phase_complete auto-advances the session"
  test "phase_complete increments the phase index and broadcasts" do
    {:ok, session} = Sessions.create_session(default_attrs())
    Sessions.subscribe(session.id)

    {:ok, _reply} = MockMCPClient.simulate_phase_complete(session.id, "done")

    assert_receive {:phase_advanced, 1}, 500
    assert Sessions.get_session(session.id).current_phase_index == 1
  end

  @tag feature: "mcp_driven_session",
       scenario: "suggest_phase_complete waits for user confirmation"
  test "suggest_phase_complete broadcasts without advancing" do
    {:ok, session} = Sessions.create_session(default_attrs())
    Sessions.subscribe(session.id)

    {:ok, _reply} =
      MockMCPClient.simulate_suggest_phase_complete(session.id, "looks done")

    assert_receive {:suggest_phase_complete, "looks done"}, 500
    assert Sessions.get_session(session.id).current_phase_index == 0
  end

  @tag feature: "mcp_driven_session",
       scenario: "New exports appear in real-time at the top of the session view"
  test "export persists a metadata row and broadcasts :export_added" do
    {:ok, session} = Sessions.create_session(default_attrs())
    Sessions.subscribe(session.id)

    {:ok, _reply} = MockMCPClient.simulate_export(session.id, "k1", "v1", type: "markdown")

    assert_receive {:export_added, _meta}, 500
    assert length(Sessions.list_exports(session.id)) == 1
  end

  defp default_attrs do
    %{workflow_name: "example", host_mode: :embedded, total_phases: 3}
  end
end
