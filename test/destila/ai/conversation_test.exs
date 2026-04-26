defmodule Destila.AI.ConversationTest do
  use DestilaWeb.ConnCase, async: false

  import Ecto.Query

  alias Destila.{AI, Repo, Workflows}
  alias Destila.AI.Session, as: AISession

  defp create_session(attrs \\ %{}, opts \\ []) do
    base = %{
      title: "Test",
      workflow_type: :brainstorm_idea,
      current_phase: 1,
      total_phases: 1
    }

    {:ok, ws} = Workflows.insert_workflow_session(Map.merge(base, attrs))

    unless opts[:skip_ai_session] do
      {:ok, _ai_session} = AI.create_ai_session(%{workflow_session_id: ws.id})
    end

    ws
  end

  defp phase_start_query(ws) do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert :processing == AI.Conversation.phase_start(ws)
    end)

    [job] = all_enqueued(worker: Destila.Workers.AiQueryWorker)
    job.args["query"]
  end

  defp count_ai_sessions(ws_id) do
    Repo.aggregate(from(s in AISession, where: s.workflow_session_id == ^ws_id), :count)
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
      assert msg.content =~ "Login to Claude action below"
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
      assert msg.content =~ "Login to Claude action below"
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
      assert msg.content =~ "Login to Claude action below"
    end

    test "auth error detected from 'Not logged in · Please run /login' result" do
      ws = create_session()

      reason = %{
        result: "Not logged in · Please run /login",
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

      assert msg.message_type == :auth_error
      assert msg.content =~ "authentication failed"
      assert msg.content =~ "Login to Claude action below"
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

    test "auth error from AuthStatusMessage tags message with :auth_error type" do
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

      assert msg.message_type == :auth_error
    end

    test "auth error detected from result text tags message with :auth_error type" do
      ws = create_session()

      reason = %{
        result:
          ~s|API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"Invalid"}}|,
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

      assert msg.message_type == :auth_error
    end

    test "non-auth error leaves message_type as nil" do
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

      assert msg.message_type == nil
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

  describe "phase_start/1 kickoff body" do
    test "brainstorm_idea phase 1 has a Prompt section and no Tools/Skills sections" do
      ws = create_session()

      query = phase_start_query(ws)
      assert query =~ "# Prompt\n\n"
      refute query =~ "# Tools"
      refute query =~ "# Skills\n\n"
      refute query =~ "# Skills (additional)"
    end

    test "code_chat phase 1 body omits # Skills (additional) (group already covers code_quality)" do
      ws = create_session(%{workflow_type: :code_chat, total_phases: 1})

      query = phase_start_query(ws)
      refute query =~ "# Skills (additional)"
      refute query =~ "# Tools"
    end

    test "implement_general_prompt phase 1 body renders Non-Interactive skill, not Code Quality" do
      ws =
        create_session(%{
          workflow_type: :implement_general_prompt,
          current_phase: 1,
          total_phases: 7
        })

      query = phase_start_query(ws)
      assert query =~ "# Skills (additional)"
      assert query =~ "## Non-Interactive Phase"
      refute query =~ "## Code Quality"
    end
  end

  describe "phase_start/1 group boundary" do
    test "phase 3 (Work) crosses a group boundary and creates a new AI session" do
      ws =
        create_session(%{
          workflow_type: :implement_general_prompt,
          current_phase: 3,
          total_phases: 7
        })

      ai_session = AI.get_ai_session_for_workflow!(ws.id)

      {:ok, _} =
        AI.update_ai_session(ai_session, %{
          worktree_path: "/tmp/wt",
          claude_session_id: "claude-abc"
        })

      assert count_ai_sessions(ws.id) == 1

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :processing == AI.Conversation.phase_start(ws)
      end)

      assert count_ai_sessions(ws.id) == 2

      # The new AI session carries the worktree forward and has no claude_session_id
      [_, newest] =
        from(s in AISession,
          where: s.workflow_session_id == ^ws.id,
          order_by: s.inserted_at
        )
        |> Repo.all()

      assert newest.worktree_path == "/tmp/wt"
      assert newest.claude_session_id == nil
    end

    test "advancing within the same group does not create a new AI session" do
      ws =
        create_session(%{
          workflow_type: :implement_general_prompt,
          current_phase: 2,
          total_phases: 7
        })

      assert count_ai_sessions(ws.id) == 1

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :processing == AI.Conversation.phase_start(ws)
      end)

      assert count_ai_sessions(ws.id) == 1
    end

    test "phase 1 on a brand-new workflow session bootstraps exactly one AI session" do
      ws =
        create_session(
          %{
            workflow_type: :implement_general_prompt,
            current_phase: 1,
            total_phases: 7
          },
          skip_ai_session: true
        )

      assert count_ai_sessions(ws.id) == 0

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :processing == AI.Conversation.phase_start(ws)
      end)

      assert count_ai_sessions(ws.id) == 1
    end
  end
end
