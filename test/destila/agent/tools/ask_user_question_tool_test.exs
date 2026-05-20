defmodule Destila.Agent.Tools.AskUserQuestionToolTest do
  use ExUnit.Case, async: false

  alias Destila.Agent.Sessions
  alias Destila.Test.MockMCPClient

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Destila.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @tag feature: "mcp_driven_session",
       scenario: "ask_user_question tool call does not block on the user's reply"
  test "returns immediately with a question id and broadcasts" do
    {:ok, session} = Sessions.create_session(default_attrs())
    Sessions.subscribe(session.id)

    {:ok, %{"result" => %{"question_id" => qid, "ok" => true}}} =
      MockMCPClient.simulate_question(session.id, "pick one", ["a", "b"])

    assert is_binary(qid)
    assert_receive {:question_asked, %{question_id: ^qid}}, 500
  end

  defp default_attrs do
    %{workflow_name: "example", host_mode: :embedded, total_phases: 1}
  end
end
