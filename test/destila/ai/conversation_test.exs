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

  describe "phase_start/1 initial-prompt wrapping and hook install" do
    defp create_session_with_worktree(tmp, attrs \\ %{}) do
      base = %{
        title: "Wrap test",
        workflow_type: :brainstorm_idea,
        current_phase: 1,
        total_phases: 4
      }

      {:ok, ws} = Workflows.insert_workflow_session(Map.merge(base, attrs))
      {:ok, _ai_session} = AI.create_ai_session(%{workflow_session_id: ws.id, worktree_path: tmp})
      ws
    end

    defp tmp_worktree do
      path =
        Path.join(
          System.tmp_dir!(),
          "conversation_phase_start_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(path)
      on_exit(fn -> File.rm_rf!(path) end)
      path
    end

    test "enqueued Oban query wraps the phase prompt in <initial-prompt> tags" do
      tmp = tmp_worktree()
      ws = create_session_with_worktree(tmp)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :processing == AI.Conversation.phase_start(ws)

        assert_enqueued(
          worker: Destila.Workers.AiQueryWorker,
          args: %{"workflow_session_id" => ws.id}
        )

        [job] = all_enqueued(worker: Destila.Workers.AiQueryWorker)
        query = job.args["query"]

        assert query =~ "# Prompt\n\n<initial-prompt>\n"
        assert query =~ "\n</initial-prompt>"
      end)
    end

    test "writes wrapped prompt, hook script, and settings.json into the worktree" do
      tmp = tmp_worktree()
      ws = create_session_with_worktree(tmp)

      Oban.Testing.with_testing_mode(:manual, fn ->
        AI.Conversation.phase_start(ws)

        [job] = all_enqueued(worker: Destila.Workers.AiQueryWorker)
        query = job.args["query"]

        # 1. prompt file matches the wrapped block present in the query
        prompt_path = Path.join(tmp, ".claude/destila/initial_prompt.txt")
        assert File.exists?(prompt_path)
        file_contents = File.read!(prompt_path)
        assert String.contains?(query, file_contents)
        assert file_contents =~ "<initial-prompt>"
        assert file_contents =~ "</initial-prompt>"

        # 2. hook script shipped and executable
        hook_path = Path.join(tmp, ".claude/hooks/reinject_initial_prompt.sh")
        assert File.exists?(hook_path)
        %File.Stat{mode: mode} = File.stat!(hook_path)
        assert Bitwise.band(mode, 0o100) == 0o100

        # 3. settings.json parses and declares the SessionStart compact hook
        settings = Jason.decode!(File.read!(Path.join(tmp, ".claude/settings.json")))
        assert [entry] = settings["hooks"]["SessionStart"]
        assert entry["matcher"] == "compact"
        assert [%{"command" => ".claude/hooks/reinject_initial_prompt.sh"}] = entry["hooks"]
      end)
    end

    test "works without a worktree_path (no files created, still enqueues)" do
      base = %{
        title: "No worktree",
        workflow_type: :brainstorm_idea,
        current_phase: 1,
        total_phases: 4
      }

      {:ok, ws} = Workflows.insert_workflow_session(base)
      {:ok, _ai_session} = AI.create_ai_session(%{workflow_session_id: ws.id})

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :processing == AI.Conversation.phase_start(ws)

        assert_enqueued(
          worker: Destila.Workers.AiQueryWorker,
          args: %{"workflow_session_id" => ws.id}
        )
      end)
    end

    test "second phase_start overwrites the prompt file with the current phase's prompt" do
      tmp = tmp_worktree()
      ws1 = create_session_with_worktree(tmp, %{current_phase: 1})

      Oban.Testing.with_testing_mode(:manual, fn ->
        AI.Conversation.phase_start(ws1)
        first = File.read!(Path.join(tmp, ".claude/destila/initial_prompt.txt"))

        ws2 = %{ws1 | current_phase: 2}
        AI.Conversation.phase_start(ws2)
        second = File.read!(Path.join(tmp, ".claude/destila/initial_prompt.txt"))

        refute first == second
        assert second =~ "<initial-prompt>"
      end)
    end
  end
end
