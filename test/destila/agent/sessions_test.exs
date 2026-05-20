defmodule Destila.Agent.SessionsTest do
  use ExUnit.Case, async: false

  alias Destila.Agent.Sessions

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Destila.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "create_session/1" do
    test "inserts a row with status :awaiting_agent" do
      {:ok, session} = Sessions.create_session(valid_attrs())

      assert session.status == :awaiting_agent
      assert session.current_phase_index == 0
      assert session.host_mode == :embedded
    end

    test "requires workflow_name and host_mode" do
      {:error, changeset} = Sessions.create_session(%{})
      errors = Keyword.keys(changeset.errors)
      assert :workflow_name in errors
      assert :host_mode in errors
    end
  end

  describe "record_event/3" do
    test "writes an event row and broadcasts" do
      {:ok, session} = Sessions.create_session(valid_attrs())
      Sessions.subscribe(session.id)

      {:ok, event} =
        Sessions.record_event(session, "session.phase_complete", %{
          tool_input: %{"a" => 1},
          tool_result: %{"ok" => true}
        })

      assert event.tool_name == "session.phase_complete"
      assert event.tool_input == %{"a" => 1}
      assert event.phase_index == 0

      assert_receive {:tool_call_event, ^event}, 500
    end
  end

  describe "advance_phase/1" do
    test "increments the phase index" do
      {:ok, session} = Sessions.create_session(Map.put(valid_attrs(), :total_phases, 3))
      {:ok, advanced} = Sessions.advance_phase(session)

      assert advanced.current_phase_index == 1
    end

    test "marks the session done when at the last phase" do
      {:ok, session} = Sessions.create_session(Map.put(valid_attrs(), :total_phases, 1))
      {:ok, done} = Sessions.advance_phase(session)

      assert done.status == :done
    end
  end

  describe "record_export/2" do
    test "stores a metadata row with agent_session_id and emits :export_added" do
      {:ok, session} = Sessions.create_session(valid_attrs())
      Sessions.subscribe(session.id)

      {:ok, meta} =
        Sessions.record_export(session, %{
          phase_name: "phase-0",
          key: "prompt",
          value: %{"value" => "hello", "type" => "text"}
        })

      assert meta.agent_session_id == session.id
      assert meta.key == "prompt"
      assert meta.exported == true

      assert_receive {:export_added, ^meta}, 500

      exports = Sessions.list_exports(session.id)
      assert length(exports) == 1
    end
  end

  defp valid_attrs do
    %{
      workflow_name: "example",
      host_mode: :embedded,
      total_phases: 2
    }
  end
end
