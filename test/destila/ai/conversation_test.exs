defmodule Destila.AI.ConversationTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.{AI, Workflows}

  defp create_session do
    {:ok, ws} =
      Workflows.insert_workflow_session(%{
        title: "Test",
        workflow_type: :brainstorm_idea,
        current_phase: 1,
        total_phases: 1
      })

    {:ok, _ai_session} = AI.create_ai_session(%{workflow_session_id: ws.id})
    ws
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
end
