defmodule Destila.AI.SessionConfigTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.{AI, Workflows}
  alias Destila.AI.SessionConfig

  defp create_session(attrs \\ %{}) do
    base = %{
      title: "Test",
      workflow_type: :brainstorm_idea,
      current_phase: 1,
      total_phases: 1
    }

    {:ok, ws} = Workflows.insert_workflow_session(Map.merge(base, attrs))
    ws
  end

  describe "session_opts_for_workflow/3 for brainstorm_idea" do
    test "omits :append_system_prompt and :allowed_tools (group has none)" do
      ws = create_session()
      {:ok, _} = AI.create_ai_session(%{workflow_session_id: ws.id})

      opts = SessionConfig.session_opts_for_workflow(ws, 1)

      refute Keyword.has_key?(opts, :append_system_prompt)
      refute Keyword.has_key?(opts, :allowed_tools)
    end

    test "forwards :ai_session_id when an AI session exists" do
      ws = create_session()
      {:ok, ai_session} = AI.create_ai_session(%{workflow_session_id: ws.id})

      opts = SessionConfig.session_opts_for_workflow(ws, 1)

      assert opts[:ai_session_id] == ai_session.id
    end

    test "omits :resume and :cwd when the AI session has none" do
      ws = create_session()
      {:ok, _} = AI.create_ai_session(%{workflow_session_id: ws.id})

      opts = SessionConfig.session_opts_for_workflow(ws, 1)

      refute Keyword.has_key?(opts, :resume)
      refute Keyword.has_key?(opts, :cwd)
    end

    test "forwards :resume and :cwd when present on the AI session" do
      ws = create_session()

      {:ok, ai_session} =
        AI.create_ai_session(%{
          workflow_session_id: ws.id,
          claude_session_id: "claude-123",
          worktree_path: "/tmp/wt"
        })

      opts = SessionConfig.session_opts_for_workflow(ws, 1)

      assert opts[:resume] == "claude-123"
      assert opts[:cwd] == "/tmp/wt"
      assert opts[:ai_session_id] == ai_session.id
    end

    test "preserves base_opts" do
      ws = create_session()
      {:ok, _} = AI.create_ai_session(%{workflow_session_id: ws.id})

      opts = SessionConfig.session_opts_for_workflow(ws, 1, timeout_ms: 1234)

      assert opts[:timeout_ms] == 1234
    end

    test "never returns :session_strategy" do
      ws = create_session()
      {:ok, _} = AI.create_ai_session(%{workflow_session_id: ws.id})

      opts = SessionConfig.session_opts_for_workflow(ws, 1)

      refute Keyword.has_key?(opts, :session_strategy)
    end

    test "registers the PreCompact hook" do
      ws = create_session()
      {:ok, _} = AI.create_ai_session(%{workflow_session_id: ws.id})

      opts = SessionConfig.session_opts_for_workflow(ws, 1)

      assert opts[:hooks] == %{PreCompact: [Destila.AI.Hooks.PreCompact]}
    end

    test ":hooks coexists with the existing session options" do
      ws = create_session()

      {:ok, _} =
        AI.create_ai_session(%{
          workflow_session_id: ws.id,
          claude_session_id: "claude-xyz",
          worktree_path: "/tmp/wt"
        })

      opts = SessionConfig.session_opts_for_workflow(ws, 1)

      assert Keyword.has_key?(opts, :hooks)
      assert opts[:resume] == "claude-xyz"
      assert opts[:cwd] == "/tmp/wt"
      assert Keyword.has_key?(opts, :ai_session_id)
    end

    test "put_hooks overwrites any base_opts :hooks entry" do
      ws = create_session()
      {:ok, _} = AI.create_ai_session(%{workflow_session_id: ws.id})

      opts =
        SessionConfig.session_opts_for_workflow(ws, 1, hooks: %{PreToolUse: [SomeOther]})

      assert opts[:hooks] == %{PreCompact: [Destila.AI.Hooks.PreCompact]}
    end
  end

  describe "session_opts_for_workflow/3 for code_chat" do
    test "renders group skills as :append_system_prompt and forwards :allowed_tools" do
      ws = create_session(%{workflow_type: :code_chat, total_phases: 1})
      {:ok, _} = AI.create_ai_session(%{workflow_session_id: ws.id})

      opts = SessionConfig.session_opts_for_workflow(ws, 1)

      assert opts[:append_system_prompt] =~ "## Code Quality"
      assert "Read" in opts[:allowed_tools]
      assert "mcp__destila__ask_user_question" in opts[:allowed_tools]
    end

    test "appends tool descriptions for the group's allowed_tools" do
      ws = create_session(%{workflow_type: :code_chat, total_phases: 1})
      {:ok, _} = AI.create_ai_session(%{workflow_session_id: ws.id})

      opts = SessionConfig.session_opts_for_workflow(ws, 1)

      assert opts[:append_system_prompt] =~ "## Phase Transitions"
      assert opts[:append_system_prompt] =~ "## Asking Questions"
      assert opts[:append_system_prompt] =~ "## Service Management"
    end
  end

  describe "session_opts_for_workflow/3 for implement_general_prompt" do
    test "Planning group (phase 1) renders code_quality system prompt and implementation tools" do
      ws =
        create_session(%{
          workflow_type: :implement_general_prompt,
          current_phase: 1,
          total_phases: 7
        })

      {:ok, _} = AI.create_ai_session(%{workflow_session_id: ws.id})

      opts = SessionConfig.session_opts_for_workflow(ws, 1)

      assert opts[:append_system_prompt] =~ "## Code Quality"
      assert "Read" in opts[:allowed_tools]
      assert "mcp__destila__session" in opts[:allowed_tools]
    end

    test "Implementation group (phase 3) uses same system prompt and tools" do
      ws =
        create_session(%{
          workflow_type: :implement_general_prompt,
          current_phase: 3,
          total_phases: 7
        })

      {:ok, _} = AI.create_ai_session(%{workflow_session_id: ws.id})

      opts_1 = SessionConfig.session_opts_for_workflow(ws, 1)
      opts_3 = SessionConfig.session_opts_for_workflow(ws, 3)

      assert opts_1[:append_system_prompt] == opts_3[:append_system_prompt]
      assert opts_1[:allowed_tools] == opts_3[:allowed_tools]
    end
  end
end
