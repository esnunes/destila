defmodule Destila.Executions.EngineTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.{AI, Executions, Workflows}
  alias Destila.Executions.Engine
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

  describe "phase_update/3 with suggest_phase_complete" do
    test "sets PE to awaiting_confirmation" do
      ws = create_session_with_ai(%{})
      {:ok, pe} = Executions.create_phase_execution(ws, 1)

      # Simulate AI response that suggests phase complete
      ai_session = AI.get_ai_session_for_workflow(ws.id)

      AI.create_message(ai_session.id, %{
        role: :system,
        content: "Ready to advance",
        phase: 1,
        workflow_session_id: ws.id
      })

      Engine.phase_update(ws.id, 1, %{
        ai_result: %{
          text: "Ready to advance",
          result: "Ready to advance",
          mcp_tool_uses: [
            %{
              name: "mcp__destila__session",
              input: %{action: "suggest_phase_complete", message: "Done"}
            }
          ]
        }
      })

      updated_pe = Executions.get_phase_execution!(pe.id)
      assert updated_pe.status == :awaiting_confirmation

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert Session.phase_status(updated_ws) == :awaiting_confirmation
    end
  end

  describe "phase_update/3 with continue conversation" do
    test "sets PE to awaiting_input" do
      ws = create_session_with_ai(%{pe_status: :processing})

      Engine.phase_update(ws.id, 1, %{
        ai_result: %{text: "More questions", result: "More questions"}
      })

      pe = Executions.get_current_phase_execution(ws.id)
      assert pe.status == :awaiting_input

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert Session.phase_status(updated_ws) == :awaiting_input
    end
  end

  describe "phase_update/3 with phase_complete on final phase" do
    test "marks workflow as done" do
      ws = create_session_with_ai(%{current_phase: 4, total_phases: 4})
      {:ok, _pe} = Executions.create_phase_execution(ws, 4)

      Engine.phase_update(ws.id, 4, %{
        ai_result: %{
          text: "Done",
          result: "Done",
          mcp_tool_uses: [
            %{
              name: "mcp__destila__session",
              input: %{action: "phase_complete", message: "All done"}
            }
          ]
        }
      })

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.done_at != nil
      assert is_nil(Session.phase_status(updated_ws))
    end
  end

  describe "phase_update/3 with phase_complete on non-final phase" do
    test "auto-advances to next phase and creates phase execution" do
      ws = create_session_with_ai(%{current_phase: 1, total_phases: 4})
      {:ok, pe} = Executions.create_phase_execution(ws, 1)

      Engine.phase_update(ws.id, 1, %{
        ai_result: %{
          text: "Phase done",
          result: "Phase done",
          mcp_tool_uses: [
            %{
              name: "mcp__destila__session",
              input: %{action: "phase_complete", message: "Moving on"}
            }
          ]
        }
      })

      updated_ws = Workflows.get_workflow_session!(ws.id)
      # Should advance to phase 2 (Gherkin Review)
      assert updated_ws.current_phase == 2
      assert is_nil(updated_ws.done_at)

      # Current phase execution should be completed
      updated_pe = Executions.get_phase_execution!(pe.id)
      assert updated_pe.status == :completed

      # New phase execution should exist for phase 2
      new_pe = Executions.get_phase_execution_by_number(ws.id, 2)
      assert new_pe != nil
      assert new_pe.phase_name == "Gherkin Review"
    end
  end

  describe "phase_update/3 with user message" do
    test "enqueues worker and sets PE status to processing" do
      ws = create_session_with_ai(%{pe_status: :awaiting_input})

      Engine.phase_update(ws.id, 1, %{message: "Hello"})

      pe = Executions.get_current_phase_execution(ws.id)
      assert pe.status == :processing

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert Session.phase_status(updated_ws) == :processing
    end

    test "updates phase_execution status from awaiting_input to processing" do
      ws = create_session_with_ai(%{pe_status: :awaiting_input})

      Engine.phase_update(ws.id, 1, %{message: "Hello"})

      pe = Executions.get_current_phase_execution(ws.id)
      assert pe.status == :processing
    end
  end

  describe "phase_update/3 with worktree_ready" do
    test "starts phase when worktree becomes ready" do
      ws = create_session_with_ai(%{})
      {:ok, _pe} = Executions.create_phase_execution(ws, 1)

      Engine.phase_update(ws.id, 1, %{worktree_ready: true})

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.current_phase == 1
      assert Session.phase_status(updated_ws) != :setup
    end
  end

  describe "phase_update/3 with export action" do
    test "stores exported metadata from AI result" do
      ws = create_session_with_ai(%{pe_status: :processing})

      Engine.phase_update(ws.id, 1, %{
        ai_result: %{
          text: "Here is the output",
          result: "Here is the output",
          mcp_tool_uses: [
            %{
              name: "mcp__destila__session",
              input: %{action: "export", key: "prompt_generated", value: "The prompt text"}
            }
          ]
        }
      })

      # Metadata should be created with exported: true
      all_metadata = Workflows.get_all_metadata(ws.id)
      exported = Enum.find(all_metadata, &(&1.key == "prompt_generated"))
      assert exported != nil
      assert exported.exported == true
      assert exported.value == %{"text" => "The prompt text"}
      assert exported.phase_name == "Task Description"

      # Should remain in awaiting_input since no phase transition action
      pe = Executions.get_current_phase_execution(ws.id)
      assert pe.status == :awaiting_input
    end

    test "processes export alongside phase_complete in same response" do
      ws = create_session_with_ai(%{current_phase: 4, total_phases: 4})
      {:ok, _pe} = Executions.create_phase_execution(ws, 4)

      Engine.phase_update(ws.id, 4, %{
        ai_result: %{
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
        }
      })

      # Metadata should be stored before phase transition
      all_metadata = Workflows.get_all_metadata(ws.id)
      exported = Enum.find(all_metadata, &(&1.key == "result"))
      assert exported != nil
      assert exported.exported == true

      # Workflow should be marked done (phase_complete on final phase)
      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.done_at != nil
    end

    test "processes multiple export actions in a single response" do
      ws = create_session_with_ai(%{pe_status: :processing})

      Engine.phase_update(ws.id, 1, %{
        ai_result: %{
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
        }
      })

      all_metadata = Workflows.get_all_metadata(ws.id)
      keys = Enum.map(all_metadata, & &1.key) |> Enum.sort()
      assert "key_one" in keys
      assert "key_two" in keys
    end

    test "skips export with nil key" do
      ws = create_session_with_ai(%{pe_status: :processing})

      Engine.phase_update(ws.id, 1, %{
        ai_result: %{
          text: "Malformed export",
          result: "Malformed export",
          mcp_tool_uses: [
            %{
              name: "mcp__destila__session",
              input: %{action: "export", key: nil, value: "orphan value"}
            }
          ]
        }
      })

      all_metadata = Workflows.get_all_metadata(ws.id)
      assert all_metadata == []
    end
  end

  describe "advance_to_next/1" do
    test "completes workflow when on last phase" do
      ws = create_session(%{current_phase: 4, total_phases: 4})

      Engine.advance_to_next(ws)

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.done_at != nil
    end

    test "advances to next phase" do
      ws = create_session_with_ai(%{current_phase: 1, total_phases: 4})

      Engine.advance_to_next(ws)

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.current_phase == 2

      # Phase execution should be created for the new phase
      pe = Executions.get_phase_execution_by_number(ws.id, 2)
      assert pe != nil
      assert pe.phase_name == "Gherkin Review"
    end

    test "completes current phase execution before advancing" do
      ws = create_session_with_ai(%{current_phase: 1, total_phases: 4})
      {:ok, pe} = Executions.create_phase_execution(ws, 1, %{status: :awaiting_confirmation})

      Engine.advance_to_next(ws)

      completed_pe = Executions.get_phase_execution!(pe.id)
      assert completed_pe.status == :completed
      assert completed_pe.completed_at != nil
    end

    test "accepts workflow session id string" do
      ws = create_session_with_ai(%{current_phase: 1, total_phases: 4})

      Engine.advance_to_next(ws.id)

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert updated_ws.current_phase == 2
    end
  end

  describe "phase_retry/1" do
    test "retries from awaiting_confirmation state" do
      ws = create_session_with_ai(%{pe_status: :awaiting_confirmation})

      Engine.phase_retry(ws)

      pe = Executions.get_current_phase_execution(ws.id)
      assert pe.status == :processing

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert Session.phase_status(updated_ws) == :processing
    end

    test "retries from awaiting_input state" do
      ws = create_session_with_ai(%{pe_status: :awaiting_input})

      Engine.phase_retry(ws)

      pe = Executions.get_current_phase_execution(ws.id)
      assert pe.status == :processing

      updated_ws = Workflows.get_workflow_session!(ws.id)
      assert Session.phase_status(updated_ws) == :processing
    end

    test "returns noop when already processing" do
      ws = create_session_with_ai(%{pe_status: :processing})

      assert Engine.phase_retry(ws) == :noop
    end
  end
end
