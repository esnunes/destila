defmodule Destila.Sessions.SessionProcessTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.{AI, Executions, Workflows}
  alias Destila.Sessions.SessionProcess
  alias Destila.Workflows.Session

  setup do
    ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
      text = "AI response"
      [ClaudeCode.Test.text(text), ClaudeCode.Test.result(text)]
    end)

    ClaudeCode.Test.set_mode_to_shared()

    :ok
  end

  defp create_session(attrs) do
    {pe_status, attrs} = Map.pop(attrs, :pe_status)

    default = %{
      title: "Test Session",
      workflow_type: :brainstorm_idea,
      current_phase: 1,
      total_phases: 4
    }

    {:ok, ws} = Workflows.insert_workflow_session(Map.merge(default, attrs))

    if pe_status do
      {:ok, _pe} = Executions.create_phase_execution(ws, ws.current_phase, %{status: pe_status})
    end

    ws
  end

  defp create_session_with_ai(attrs) do
    ws = create_session(attrs)
    {:ok, _ai_session} = AI.create_ai_session(%{workflow_session_id: ws.id})
    ws
  end

  defp start_process(ws_id) do
    {:ok, _pid} = SessionProcess.ensure_started(ws_id)
    sync_process(ws_id)

    on_exit(fn ->
      name = {:via, Registry, {Destila.Sessions.Registry, ws_id}}

      case GenServer.whereis(name) do
        nil -> :ok
        pid -> :gen_statem.stop(pid)
      end
    end)
  end

  defp sync_process(ws_id) do
    name = {:via, Registry, {Destila.Sessions.Registry, ws_id}}

    case GenServer.whereis(name) do
      nil -> :ok
      pid -> _ = :sys.get_state(pid)
    end
  end

  describe "AI response with suggest_phase_complete" do
    test "sets PE to awaiting_confirmation" do
      ws = create_session_with_ai(%{})
      {:ok, pe} = Executions.create_phase_execution(ws, 1)

      start_process(ws.id)

      # Simulate AI response that suggests phase complete
      ai_session = AI.get_ai_session_for_workflow(ws.id)

      AI.create_message(ai_session.id, %{
        role: :system,
        content: "Ready to advance",
        phase: 1,
        workflow_session_id: ws.id
      })

      SessionProcess.ai_response(
        ws.id,
        %{
          text: "Ready to advance",
          result: "Ready to advance",
          mcp_tool_uses: [
            %{
              name: "mcp__destila__session",
              input: %{action: "suggest_phase_complete", message: "Done"}
            }
          ]
        },
        1
      )

      sync_process(ws.id)

      updated_pe = Executions.get_phase_execution!(pe.id)
      assert updated_pe.status == :awaiting_confirmation

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert Session.phase_status(updated_ws) == :awaiting_confirmation
    end
  end

  describe "AI response with continue conversation" do
    test "sets PE to awaiting_input" do
      ws = create_session_with_ai(%{pe_status: :processing})
      start_process(ws.id)

      SessionProcess.ai_response(
        ws.id,
        %{text: "More questions", result: "More questions"},
        1
      )

      sync_process(ws.id)

      pe = Executions.get_current_phase_execution(ws.id)
      assert pe.status == :awaiting_input

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert Session.phase_status(updated_ws) == :awaiting_input
    end
  end

  describe "AI response with phase_complete on final phase" do
    test "marks workflow as done" do
      ws = create_session_with_ai(%{current_phase: 4, total_phases: 4})
      {:ok, _pe} = Executions.create_phase_execution(ws, 4)

      start_process(ws.id)

      SessionProcess.ai_response(
        ws.id,
        %{
          text: "Done",
          result: "Done",
          mcp_tool_uses: [
            %{
              name: "mcp__destila__session",
              input: %{action: "phase_complete", message: "All done"}
            }
          ]
        },
        4
      )

      sync_process(ws.id)

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.done_at != nil
      assert is_nil(Session.phase_status(updated_ws))
    end
  end

  describe "AI response with phase_complete on non-final phase" do
    test "auto-advances to next phase and creates phase execution" do
      ws = create_session_with_ai(%{current_phase: 1, total_phases: 4})
      {:ok, pe} = Executions.create_phase_execution(ws, 1)

      start_process(ws.id)

      SessionProcess.ai_response(
        ws.id,
        %{
          text: "Phase done",
          result: "Phase done",
          mcp_tool_uses: [
            %{
              name: "mcp__destila__session",
              input: %{action: "phase_complete", message: "Moving on"}
            }
          ]
        },
        1
      )

      sync_process(ws.id)

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.current_phase == 2
      assert is_nil(updated_ws.done_at)

      updated_pe = Executions.get_phase_execution!(pe.id)
      assert updated_pe.status == :completed

      new_pe = Executions.get_phase_execution_by_number(ws.id, 2)
      assert new_pe != nil
      assert new_pe.phase_name == "Gherkin Review"
    end
  end

  describe "send_message" do
    test "enqueues worker and sets PE status to processing" do
      ws = create_session_with_ai(%{pe_status: :awaiting_input})
      start_process(ws.id)

      {:ok, updated_ws} = SessionProcess.send_message(ws.id, "Hello")

      pe = Executions.get_current_phase_execution(ws.id)
      assert pe.status == :processing

      assert Session.phase_status(updated_ws) == :processing
    end
  end

  describe "AI response with export action" do
    test "stores exported metadata from AI result" do
      ws = create_session_with_ai(%{pe_status: :processing})
      start_process(ws.id)

      SessionProcess.ai_response(
        ws.id,
        %{
          text: "Here is the output",
          result: "Here is the output",
          mcp_tool_uses: [
            %{
              name: "mcp__destila__session",
              input: %{action: "export", key: "prompt_generated", value: "The prompt text"}
            }
          ]
        },
        1
      )

      sync_process(ws.id)

      all_metadata = Workflows.get_all_metadata(ws.id)
      exported = Enum.find(all_metadata, &(&1.key == "prompt_generated"))
      assert exported != nil
      assert exported.exported == true
      assert exported.value == %{"text" => "The prompt text"}
      assert exported.phase_name == "Task Description"

      pe = Executions.get_current_phase_execution(ws.id)
      assert pe.status == :awaiting_input
    end

    test "processes export alongside phase_complete in same response" do
      ws = create_session_with_ai(%{current_phase: 4, total_phases: 4})
      {:ok, _pe} = Executions.create_phase_execution(ws, 4)

      start_process(ws.id)

      SessionProcess.ai_response(
        ws.id,
        %{
          text: "Final output",
          result: "Final output",
          mcp_tool_uses: [
            %{
              name: "mcp__destila__session",
              input: %{action: "export", key: "result", value: "The result"}
            },
            %{
              name: "mcp__destila__session",
              input: %{action: "phase_complete", message: "All done"}
            }
          ]
        },
        4
      )

      sync_process(ws.id)

      all_metadata = Workflows.get_all_metadata(ws.id)
      exported = Enum.find(all_metadata, &(&1.key == "result"))
      assert exported != nil
      assert exported.exported == true

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.done_at != nil
    end

    test "processes multiple export actions in a single response" do
      ws = create_session_with_ai(%{pe_status: :processing})
      start_process(ws.id)

      SessionProcess.ai_response(
        ws.id,
        %{
          text: "Exporting multiple items",
          result: "Exporting multiple items",
          mcp_tool_uses: [
            %{
              name: "mcp__destila__session",
              input: %{action: "export", key: "key_one", value: "value one"}
            },
            %{
              name: "mcp__destila__session",
              input: %{action: "export", key: "key_two", value: "value two"}
            }
          ]
        },
        1
      )

      sync_process(ws.id)

      all_metadata = Workflows.get_all_metadata(ws.id)
      keys = Enum.map(all_metadata, & &1.key) |> Enum.sort()
      assert "key_one" in keys
      assert "key_two" in keys
    end

    test "skips export with nil key" do
      ws = create_session_with_ai(%{pe_status: :processing})
      start_process(ws.id)

      SessionProcess.ai_response(
        ws.id,
        %{
          text: "Malformed export",
          result: "Malformed export",
          mcp_tool_uses: [
            %{
              name: "mcp__destila__session",
              input: %{action: "export", key: nil, value: "orphan value"}
            }
          ]
        },
        1
      )

      sync_process(ws.id)

      all_metadata = Workflows.get_all_metadata(ws.id)
      assert all_metadata == []
    end
  end

  describe "confirm_advance" do
    test "completes workflow when on last phase" do
      ws =
        create_session_with_ai(%{
          current_phase: 4,
          total_phases: 4,
          pe_status: :awaiting_confirmation
        })

      start_process(ws.id)

      {:ok, updated_ws} = SessionProcess.confirm_advance(ws.id)
      assert updated_ws.done_at != nil
    end

    test "advances to next phase" do
      ws =
        create_session_with_ai(%{
          current_phase: 1,
          total_phases: 4,
          pe_status: :awaiting_confirmation
        })

      start_process(ws.id)

      {:ok, updated_ws} = SessionProcess.confirm_advance(ws.id)
      assert updated_ws.current_phase == 2

      pe = Executions.get_phase_execution_by_number(ws.id, 2)
      assert pe != nil
      assert pe.phase_name == "Gherkin Review"
    end

    test "completes current phase execution before advancing" do
      ws =
        create_session_with_ai(%{
          current_phase: 1,
          total_phases: 4,
          pe_status: :awaiting_confirmation
        })

      pe = Executions.get_current_phase_execution(ws.id)

      start_process(ws.id)

      {:ok, _ws} = SessionProcess.confirm_advance(ws.id)

      completed_pe = Executions.get_phase_execution!(pe.id)
      assert completed_pe.status == :completed
      assert completed_pe.completed_at != nil
    end
  end

  describe "retry" do
    test "retries from awaiting_confirmation state" do
      ws = create_session_with_ai(%{pe_status: :awaiting_confirmation})
      start_process(ws.id)

      {:ok, _ws} = SessionProcess.retry(ws.id)

      pe = Executions.get_current_phase_execution(ws.id)
      assert pe.status == :processing

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert Session.phase_status(updated_ws) == :processing
    end

    test "retries from awaiting_input state" do
      ws = create_session_with_ai(%{pe_status: :awaiting_input})
      start_process(ws.id)

      {:ok, _ws} = SessionProcess.retry(ws.id)

      pe = Executions.get_current_phase_execution(ws.id)
      assert pe.status == :processing

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert Session.phase_status(updated_ws) == :processing
    end

    test "returns error when already processing" do
      ws = create_session_with_ai(%{pe_status: :processing})
      start_process(ws.id)

      assert {:error, :invalid_event} = SessionProcess.retry(ws.id)
    end
  end

  describe "decline_advance" do
    test "rejects completion and returns to awaiting_input" do
      ws = create_session_with_ai(%{pe_status: :awaiting_confirmation})
      start_process(ws.id)

      {:ok, updated_ws} = SessionProcess.decline_advance(ws.id)

      pe = Executions.get_current_phase_execution(ws.id)
      assert pe.status == :awaiting_input
      assert Session.phase_status(updated_ws) == :awaiting_input
    end
  end

  describe "mark_done and mark_undone" do
    test "marks session as done" do
      ws = create_session_with_ai(%{pe_status: :awaiting_input})
      start_process(ws.id)

      {:ok, updated_ws} = SessionProcess.mark_done(ws.id)
      assert updated_ws.done_at != nil
    end

    test "mark_undone reopens a done session" do
      ws = create_session_with_ai(%{pe_status: :awaiting_input})
      start_process(ws.id)

      {:ok, _ws} = SessionProcess.mark_done(ws.id)
      {:ok, updated_ws} = SessionProcess.mark_undone(ws.id)
      assert is_nil(updated_ws.done_at)
    end
  end

  describe "cancel" do
    test "cancels processing and returns to awaiting_input" do
      ws = create_session_with_ai(%{pe_status: :processing})
      start_process(ws.id)

      {:ok, _ws} = SessionProcess.cancel(ws.id)

      pe = Executions.get_current_phase_execution(ws.id)
      assert pe.status == :awaiting_input
    end
  end

  describe "stale AI response" do
    test "ignores AI response from a different phase" do
      ws = create_session_with_ai(%{current_phase: 2, total_phases: 4, pe_status: :processing})
      start_process(ws.id)

      SessionProcess.ai_response(ws.id, %{text: "Stale", result: "Stale"}, 1)
      sync_process(ws.id)

      pe = Executions.get_current_phase_execution(ws.id)
      assert pe.status == :processing
    end
  end
end
