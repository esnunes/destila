defmodule Destila.AI.ConversationTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.{AI, Workflows}

  defp create_session(attrs \\ %{}) do
    base = %{
      title: "Test",
      workflow_type: :brainstorm_idea,
      current_phase: 1,
      total_phases: 1
    }

    {:ok, ws} = Workflows.insert_workflow_session(Map.merge(base, attrs))
    {:ok, _ai_session} = AI.create_ai_session(%{workflow_session_id: ws.id})
    ws
  end

  defp ok_result(opts \\ []) do
    %{
      result: Keyword.get(opts, :result, "done"),
      is_error: false,
      errors: nil,
      text: Keyword.get(opts, :text, ""),
      session_id: nil,
      subtype: :success,
      auth_error: nil,
      mcp_tool_uses: Keyword.get(opts, :mcp_tool_uses, [])
    }
  end

  defp session_tool_use(action, message) do
    %{name: "mcp__destila__session", input: %{action: action, message: message}}
  end

  defp last_message(ws_id) do
    ws_id
    |> AI.list_messages_for_workflow_session()
    |> List.last()
  end

  describe "handle_ai_error/2" do
    test "auth error from AuthStatusMessage" do
      ws = create_session()

      reason = %{
        result: nil,
        is_error: true,
        errors: nil,
        text: "",
        session_id: nil,
        subtype: :error_during_execution,
        auth_error: "Invalid key",
        mcp_tool_uses: []
      }

      AI.Conversation.handle_ai_error(ws, reason)
      msg = last_message(ws.id)

      assert msg.content =~ "authentication failed: Invalid key"
      assert msg.content =~ "claude login"
    end

    test "auth error detected from result text containing authentication_error" do
      ws = create_session()

      reason = %{
        result:
          ~s|Failed to authenticate. API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"Invalid authentication credentials"}}|,
        is_error: true,
        errors: nil,
        text: "",
        session_id: nil,
        subtype: :error_during_execution,
        auth_error: nil,
        mcp_tool_uses: []
      }

      AI.Conversation.handle_ai_error(ws, reason)
      msg = last_message(ws.id)

      assert msg.content =~ "authentication failed"
      assert msg.content =~ "claude login"
    end

    test "auth error detected from errors list containing authentication_error" do
      ws = create_session()

      reason = %{
        result: nil,
        is_error: true,
        errors: [
          ~s|API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"Invalid authentication credentials"}}|
        ],
        text: "",
        session_id: nil,
        subtype: :error_during_execution,
        auth_error: nil,
        mcp_tool_uses: []
      }

      AI.Conversation.handle_ai_error(ws, reason)
      msg = last_message(ws.id)

      assert msg.content =~ "authentication failed"
      assert msg.content =~ "claude login"
    end

    test "non-auth error with errors list shows the errors" do
      ws = create_session()

      reason = %{
        result: nil,
        is_error: true,
        errors: ["Rate limit exceeded"],
        text: "",
        session_id: nil,
        subtype: :error_during_execution,
        auth_error: nil,
        mcp_tool_uses: []
      }

      AI.Conversation.handle_ai_error(ws, reason)
      msg = last_message(ws.id)

      assert msg.content =~ "Rate limit exceeded"
      refute msg.content =~ "authentication"
    end

    test "non-auth error with result text shows the error" do
      ws = create_session()

      reason = %{
        result: "Rate limit exceeded",
        is_error: true,
        errors: nil,
        text: "",
        session_id: nil,
        subtype: :error_during_execution,
        auth_error: nil,
        mcp_tool_uses: []
      }

      AI.Conversation.handle_ai_error(ws, reason)
      msg = last_message(ws.id)

      assert msg.content =~ "Rate limit exceeded"
    end

    test "CLI not found error" do
      ws = create_session()

      AI.Conversation.handle_ai_error(ws, {:cli_not_found, "Claude CLI not found in PATH"})
      msg = last_message(ws.id)

      assert msg.content =~ "Claude CLI not found"
    end

    test "CLI initialization failure" do
      ws = create_session()

      reason = {:provisioning_failed, {:initialize_failed, "Connection refused"}}
      AI.Conversation.handle_ai_error(ws, reason)
      msg = last_message(ws.id)

      assert msg.content =~ "Connection refused"
    end

    test "CLI exit error" do
      ws = create_session()

      reason = {:provisioning_failed, {:cli_exit, 1}}
      AI.Conversation.handle_ai_error(ws, reason)
      msg = last_message(ws.id)

      assert msg.content =~ "exit code 1"
    end

    test "CLI timeout error" do
      ws = create_session()

      reason = {:provisioning_failed, :initialize_timeout}
      AI.Conversation.handle_ai_error(ws, reason)
      msg = last_message(ws.id)

      assert msg.content =~ "timed out"
    end

    test "unknown error falls back to generic message" do
      ws = create_session()

      AI.Conversation.handle_ai_error(ws, :something_unexpected)
      msg = last_message(ws.id)

      assert msg.content == "Something went wrong. Please try sending your message again."
    end

    test "always returns :awaiting_input" do
      ws = create_session()
      assert :awaiting_input == AI.Conversation.handle_ai_error(ws, :error)
    end
  end

  describe "handle_ai_result/2" do
    test "interactive phase with no session action returns :awaiting_input" do
      ws = create_session()
      assert :awaiting_input == AI.Conversation.handle_ai_result(ws, ok_result())
    end

    test "non-interactive phase with no session action auto-advances" do
      ws =
        create_session(%{
          workflow_type: :implement_general_prompt,
          current_phase: 1,
          total_phases: 7
        })

      assert :phase_complete == AI.Conversation.handle_ai_result(ws, ok_result())
    end

    test "explicit phase_complete takes precedence on non-interactive phase" do
      ws =
        create_session(%{
          workflow_type: :implement_general_prompt,
          current_phase: 1,
          total_phases: 7
        })

      result = ok_result(mcp_tool_uses: [session_tool_use("phase_complete", "done")])
      assert :phase_complete == AI.Conversation.handle_ai_result(ws, result)
    end

    test "explicit suggest_phase_complete on interactive phase" do
      ws = create_session()

      result = ok_result(mcp_tool_uses: [session_tool_use("suggest_phase_complete", "ok?")])
      assert :suggest_phase_complete == AI.Conversation.handle_ai_result(ws, result)
    end

    test "interactive adjustments phase with no session action stays awaiting_input" do
      ws =
        create_session(%{
          workflow_type: :implement_general_prompt,
          current_phase: 7,
          total_phases: 7
        })

      assert :awaiting_input == AI.Conversation.handle_ai_result(ws, ok_result())
    end
  end
end
