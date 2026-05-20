defmodule Destila.Agent.EventRouterTest do
  use ExUnit.Case, async: false

  alias Destila.Agent.{EventRouter, Sessions, SessionServer}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Destila.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  test "tools/list returns the canonical tool schemas" do
    reply = EventRouter.handle_rpc("does-not-matter", rpc("tools/list", %{}))

    assert %{"result" => %{"tools" => tools}} = reply
    names = Enum.map(tools, & &1["name"])
    assert "session" in names
    assert "ask_user_question" in names
    assert "service" in names
    assert "exports_read" in names
  end

  test "tools/call for an unknown tool returns method-not-found" do
    {:ok, session} = Sessions.create_session(default_attrs())
    {:ok, _pid} = SessionServer.ensure_started(session.id)

    reply =
      EventRouter.handle_rpc(
        session.id,
        rpc("tools/call", %{"name" => "no_such_tool", "arguments" => %{}})
      )

    assert %{"error" => %{"code" => -32601}} = reply
  end

  test "invalid request shape returns an Invalid Request envelope" do
    reply = EventRouter.handle_rpc("anything", %{"foo" => "bar"})
    assert %{"error" => %{"code" => -32600}} = reply
  end

  test "initialize replies with serverInfo" do
    reply = EventRouter.handle_rpc("anything", rpc("initialize", %{}))
    assert %{"result" => %{"serverInfo" => %{"name" => "destila"}}} = reply
  end

  defp rpc(method, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => params
    }
  end

  defp default_attrs do
    %{workflow_name: "example", host_mode: :embedded, total_phases: 2}
  end
end
