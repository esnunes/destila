defmodule Destila.Agent.Tools.ExportsReadToolTest do
  use ExUnit.Case, async: false

  alias Destila.Agent.Sessions
  alias Destila.Test.MockMCPClient

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Destila.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @tag feature: "mcp_driven_session",
       scenario: "Exports from prior phases remain available across handoff"
  test "returns all exports including ones from prior phases" do
    {:ok, session} = Sessions.create_session(default_attrs())

    {:ok, _} = MockMCPClient.simulate_export(session.id, "alpha", "first")
    {:ok, _} = MockMCPClient.simulate_phase_complete(session.id, "moving on")
    {:ok, _} = MockMCPClient.simulate_export(session.id, "beta", "second")

    {:ok, reply} = MockMCPClient.simulate_tool_call(session.id, "exports_read", %{})
    keys = reply["result"]["exports"] |> Enum.map(& &1["key"])

    assert "alpha" in keys
    assert "beta" in keys
  end

  test "returns empty list when no exports exist" do
    {:ok, session} = Sessions.create_session(default_attrs())

    {:ok, reply} = MockMCPClient.simulate_tool_call(session.id, "exports_read", %{})
    assert reply["result"]["exports"] == []
  end

  defp default_attrs do
    %{workflow_name: "example", host_mode: :embedded, total_phases: 2}
  end
end
