defmodule DestilaWeb.AiSessionDetailLiveTest do
  @moduledoc """
  LiveView tests for the AI Session Debug Detail page.
  Feature: features/ai_session_detail.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ClaudeCode.Content.{
    CompactionBlock,
    ImageBlock,
    MCPToolResultBlock,
    MCPToolUseBlock,
    RedactedThinkingBlock,
    ServerToolResultBlock,
    ServerToolUseBlock,
    TextBlock,
    ThinkingBlock,
    ToolResultBlock,
    ToolUseBlock
  }

  alias ClaudeCode.History.SessionMessage
  alias Destila.AI
  alias Destila.AI.{AlivenessTracker, FakeHistory}

  setup %{conn: conn} do
    ClaudeCode.Test.set_mode_to_shared()

    ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
      [
        ClaudeCode.Test.text("AI response"),
        ClaudeCode.Test.result("AI response")
      ]
    end)

    FakeHistory.reset()

    {:ok, conn: conn}
  end

  defp create_session do
    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test Session",
        workflow_type: :brainstorm_idea,
        project_id: nil,
        done_at: DateTime.utc_now(),
        current_phase: 4,
        total_phases: 4
      })

    ws
  end

  defp create_ai_session(ws, attrs \\ %{}) do
    claude_session_id = Map.get(attrs, :claude_session_id, Ecto.UUID.generate())

    {:ok, ai} =
      AI.create_ai_session(
        Map.merge(
          %{
            workflow_session_id: ws.id,
            worktree_path: System.tmp_dir!(),
            claude_session_id: claude_session_id
          },
          attrs
        )
      )

    ai
  end

  defp assistant_message(content_blocks) do
    %SessionMessage{
      type: :assistant,
      uuid: Ecto.UUID.generate(),
      session_id: "test-session",
      message: %{content: content_blocks},
      parent_tool_use_id: nil
    }
  end

  defp user_message(content) do
    %SessionMessage{
      type: :user,
      uuid: Ecto.UUID.generate(),
      session_id: "test-session",
      message: %{content: content, role: :user},
      parent_tool_use_id: nil
    }
  end

  describe "mount + header" do
    @tag feature: "ai_session_detail",
         scenario: "Header shows creation date and Claude session id"
    test "renders header with creation date and claude_session_id", %{conn: conn} do
      ws = create_session()
      claude_session_id = Ecto.UUID.generate()
      ai = create_ai_session(ws, %{claude_session_id: claude_session_id})
      FakeHistory.stub(claude_session_id, {:ok, []})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      assert has_element?(view, "#ai-session-header")
      assert has_element?(view, "#ai-session-claude-id", claude_session_id)
    end

    @tag feature: "ai_session_detail",
         scenario: "Back link navigates to the parent workflow runner"
    test "back link points to the parent workflow runner", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)
      FakeHistory.stub(ai.claude_session_id, {:ok, []})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      assert has_element?(
               view,
               ~s|#ai-session-back-link[href="/sessions/#{ws.id}"]|
             )
    end

    @tag feature: "ai_session_detail",
         scenario: "Unknown workflow session id redirects to the crafting board"
    test "unknown workflow session id redirects to /crafting", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      assert {:error, {:live_redirect, %{to: "/crafting"}}} =
               live(conn, ~p"/sessions/#{Ecto.UUID.generate()}/ai/#{ai.id}")
    end

    @tag feature: "ai_session_detail",
         scenario: "Unknown AI session id redirects to the workflow runner"
    test "unknown ai_session_id redirects to the workflow runner page", %{conn: conn} do
      ws = create_session()

      assert {:error, {:live_redirect, %{to: path}}} =
               live(conn, ~p"/sessions/#{ws.id}/ai/#{Ecto.UUID.generate()}")

      assert path == "/sessions/#{ws.id}"
    end

    @tag feature: "ai_session_detail",
         scenario: "AI session belonging to another workflow is rejected"
    test "ai_session from a different workflow redirects to the parent workflow", %{conn: conn} do
      ws1 = create_session()
      ws2 = create_session()
      ai = create_ai_session(ws2)

      assert {:error, {:live_redirect, %{to: path}}} =
               live(conn, ~p"/sessions/#{ws1.id}/ai/#{ai.id}")

      assert path == "/sessions/#{ws1.id}"
    end
  end

  describe "empty states" do
    @tag feature: "ai_session_detail", scenario: "Missing Claude session id shows empty state"
    test "renders empty state when claude_session_id is nil", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws, %{claude_session_id: nil})

      {:ok, _view, html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      assert html =~ "No conversation history available"
    end

    @tag feature: "ai_session_detail", scenario: "Empty history shows empty state"
    test "renders empty state when history is empty", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)
      FakeHistory.stub(ai.claude_session_id, {:ok, []})

      {:ok, _view, html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      assert html =~ "No conversation history available"
    end

    @tag feature: "ai_session_detail", scenario: "History read failure shows empty state"
    test "renders error empty state when history adapter returns an error", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)
      FakeHistory.stub(ai.claude_session_id, {:error, :enoent})

      {:ok, _view, html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      assert html =~ "Unable to read conversation history"
    end
  end

  describe "aliveness live updates" do
    @tag feature: "ai_session_detail", scenario: "Aliveness dot toggles live on the detail page"
    test "broadcasting an ai-aliveness change updates the detail page", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)
      FakeHistory.stub(ai.claude_session_id, {:ok, []})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      Phoenix.PubSub.broadcast(
        Destila.PubSub,
        AlivenessTracker.topic(),
        {:aliveness_changed_ai, ai.id, true}
      )

      assert render(view) =~ "bg-success"
    end
  end

  describe "history live updates" do
    @tag feature: "ai_session_detail",
         scenario: "Stream chunk triggers debounced history reload"
    test "appends new messages after a chunk broadcast followed by reload fire", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      initial = [user_message("first")]
      FakeHistory.stub(ai.claude_session_id, {:ok, initial})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")
      assert render(view) =~ "first"

      appended =
        initial ++
          [assistant_message([%TextBlock{type: "text", text: "second"}])]

      FakeHistory.stub(ai.claude_session_id, {:ok, appended})

      Phoenix.PubSub.broadcast(
        Destila.PubSub,
        Destila.PubSubHelper.ai_stream_topic(ws.id),
        {:ai_stream_chunk, :any}
      )

      send(view.pid, :reload_history)

      html = render(view)
      assert html =~ "first"
      assert html =~ "second"
    end

    @tag feature: "ai_session_detail",
         scenario: "Stream chunk transitions empty history to loaded"
    test "promotes :empty state to :loaded when new messages arrive", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      FakeHistory.stub(ai.claude_session_id, {:ok, []})

      {:ok, view, html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")
      assert html =~ "No conversation history available"

      FakeHistory.stub(
        ai.claude_session_id,
        {:ok, [assistant_message([%TextBlock{type: "text", text: "arrived"}])]}
      )

      Phoenix.PubSub.broadcast(
        Destila.PubSub,
        Destila.PubSubHelper.ai_stream_topic(ws.id),
        {:ai_stream_chunk, :any}
      )

      send(view.pid, :reload_history)

      html = render(view)
      assert html =~ "arrived"
      refute html =~ "No conversation history available"
    end

    @tag feature: "ai_session_detail",
         scenario: "Debounced reload does not duplicate messages"
    test "multiple chunk broadcasts before reload do not duplicate messages", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      messages = [
        user_message("hello"),
        assistant_message([%TextBlock{type: "text", text: "world"}])
      ]

      FakeHistory.stub(ai.claude_session_id, {:ok, messages})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      for _ <- 1..5 do
        Phoenix.PubSub.broadcast(
          Destila.PubSub,
          Destila.PubSubHelper.ai_stream_topic(ws.id),
          {:ai_stream_chunk, :any}
        )
      end

      send(view.pid, :reload_history)

      html = render(view)
      first_hello = :binary.match(html, "hello")
      assert first_hello != :nomatch
      {start, len} = first_hello
      rest = binary_part(html, start + len, byte_size(html) - start - len)
      refute rest =~ "hello"
    end
  end

  describe "content block rendering" do
    @tag feature: "ai_session_detail", scenario: "Text blocks render in order"
    test "renders user and assistant text blocks in order", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      messages = [
        user_message("hello there"),
        assistant_message([%TextBlock{type: "text", text: "hi back"}])
      ]

      FakeHistory.stub(ai.claude_session_id, {:ok, messages})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      assert has_element?(view, ~s|[data-message-role="user"]|)
      assert has_element?(view, ~s|[data-message-role="assistant"]|)
      assert render(view) =~ "hello there"
      assert render(view) =~ "hi back"
    end

    @tag feature: "ai_session_detail", scenario: "Thinking block renders collapsed by default"
    test "renders thinking block as collapsed <details>", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      messages = [
        assistant_message([
          %ThinkingBlock{type: "thinking", thinking: "deep thoughts", signature: "sig"}
        ])
      ]

      FakeHistory.stub(ai.claude_session_id, {:ok, messages})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      assert has_element?(view, ~s|details[data-block-type="thinking"]|)

      refute render(view) =~
               ~s|<details data-block-type="thinking" class="rounded-md border border-base-300/60 bg-base-200/40" open|
    end

    @tag feature: "ai_session_detail",
         scenario: "Thinking block with empty content renders as a placeholder"
    test "renders empty thinking block as placeholder", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      messages = [
        assistant_message([
          %ThinkingBlock{type: "thinking", thinking: "", signature: "sig"}
        ])
      ]

      FakeHistory.stub(ai.claude_session_id, {:ok, messages})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      refute has_element?(view, ~s|details[data-block-type="thinking"]|)
      assert has_element?(view, ~s|div[data-block-type="thinking"]|)
      assert render(view) =~ "not preserved in transcript"
    end

    @tag feature: "ai_session_detail",
         scenario: "Redacted thinking block renders as a placeholder"
    test "renders redacted thinking block placeholder", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      messages = [
        assistant_message([
          %RedactedThinkingBlock{type: "redacted_thinking", data: "abcd"}
        ])
      ]

      FakeHistory.stub(ai.claude_session_id, {:ok, messages})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      assert has_element?(view, ~s|[data-block-type="redacted_thinking"]|)
      assert render(view) =~ "Redacted thinking"
    end

    @tag feature: "ai_session_detail",
         scenario: "Tool use block renders tool name and pretty JSON input"
    test "renders tool use block with name and pretty JSON input", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      messages = [
        assistant_message([
          %ToolUseBlock{
            type: "tool_use",
            id: "toolu_1",
            name: "Read",
            input: %{"path" => "/tmp/foo.txt"}
          }
        ])
      ]

      FakeHistory.stub(ai.claude_session_id, {:ok, messages})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      assert has_element?(
               view,
               ~s|[data-block-type="tool_use"][data-tool-use-id="toolu_1"]|
             )

      html = render(view)
      assert html =~ "Read"
      assert html =~ "/tmp/foo.txt"
    end

    @tag feature: "ai_session_detail", scenario: "Tool result block is paired with its tool use"
    test "tool result block references the originating tool use id and carries the tool name",
         %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      messages = [
        assistant_message([
          %ToolUseBlock{
            type: "tool_use",
            id: "toolu_1",
            name: "Read",
            input: %{"path" => "/tmp/foo.txt"}
          }
        ]),
        user_message([
          %ToolResultBlock{
            type: "tool_result",
            tool_use_id: "toolu_1",
            content: "file contents",
            is_error: false
          }
        ])
      ]

      FakeHistory.stub(ai.claude_session_id, {:ok, messages})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      assert has_element?(
               view,
               ~s|[data-block-type="tool_result"][data-tool-use-ref="toolu_1"][data-tool-name="Read"]|
             )
    end

    @tag feature: "ai_session_detail",
         scenario: "Tool result with is_error renders with an error style"
    test "tool result block with is_error true renders with error styling", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      messages = [
        user_message([
          %ToolResultBlock{
            type: "tool_result",
            tool_use_id: "toolu_1",
            content: "boom",
            is_error: true
          }
        ])
      ]

      FakeHistory.stub(ai.claude_session_id, {:ok, messages})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      html = render(view)
      assert html =~ ~s|data-block-type="tool_result"|
      assert html =~ "border-error"
    end

    @tag feature: "ai_session_detail",
         scenario: "Server tool use and result render with a server tool badge"
    test "server tool blocks render with a server tool label", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      messages = [
        assistant_message([
          %ServerToolUseBlock{
            type: "server_tool_use",
            id: "srv_1",
            name: "web_search",
            input: %{"q" => "elixir"}
          }
        ]),
        user_message([
          %ServerToolResultBlock{
            type: "server_tool_result",
            tool_use_id: "srv_1",
            content: "[result]"
          }
        ])
      ]

      FakeHistory.stub(ai.claude_session_id, {:ok, messages})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      html = render(view)
      assert html =~ ~s|data-block-type="server_tool_use"|
      assert html =~ ~s|data-block-type="server_tool_result"|
      assert html =~ "server tool"
    end

    @tag feature: "ai_session_detail",
         scenario: "MCP tool blocks render with server_name and tool name"
    test "MCP tool result block with is_error true renders with error styling", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      messages = [
        user_message([
          %MCPToolResultBlock{
            type: "mcp_tool_result",
            tool_use_id: "mcp_1",
            content: "boom",
            is_error: true
          }
        ])
      ]

      FakeHistory.stub(ai.claude_session_id, {:ok, messages})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      html = render(view)
      assert html =~ ~s|data-block-type="mcp_tool_result"|
      assert html =~ "border-error"
    end

    @tag feature: "ai_session_detail",
         scenario: "MCP tool blocks render with server_name and tool name"
    test "MCP tool use block shows server name and tool name", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      messages = [
        assistant_message([
          %MCPToolUseBlock{
            type: "mcp_tool_use",
            id: "mcp_1",
            name: "list_files",
            server_name: "my-server",
            input: %{"path" => "/"}
          }
        ])
      ]

      FakeHistory.stub(ai.claude_session_id, {:ok, messages})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      html = render(view)
      assert html =~ ~s|data-block-type="mcp_tool_use"|
      assert html =~ "my-server"
      assert html =~ "list_files"
    end

    @tag feature: "ai_session_detail",
         scenario: "Image block with URL source renders an img element"
    test "image block with URL source renders an <img>", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      messages = [
        assistant_message([
          %ImageBlock{
            type: "image",
            source: %{type: :url, url: "https://example.com/cat.png"}
          }
        ])
      ]

      FakeHistory.stub(ai.claude_session_id, {:ok, messages})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      assert has_element?(view, ~s|img[src="https://example.com/cat.png"]|)
    end

    @tag feature: "ai_session_detail",
         scenario: "Image block with base64 source renders a placeholder"
    test "image block with base64 source renders a placeholder (no img element)", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      messages = [
        assistant_message([
          %ImageBlock{
            type: "image",
            source: %{type: :base64, media_type: "image/png", data: "AAAA"}
          }
        ])
      ]

      FakeHistory.stub(ai.claude_session_id, {:ok, messages})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      html = render(view)
      assert html =~ ~s|data-image-kind="base64"|
      refute html =~ ~s|<img|
    end

    @tag feature: "ai_session_detail", scenario: "Compaction block renders a visible marker"
    test "compaction block renders a compaction marker", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      messages = [
        assistant_message([
          %CompactionBlock{type: "compaction", content: "summary"}
        ])
      ]

      FakeHistory.stub(ai.claude_session_id, {:ok, messages})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      html = render(view)
      assert html =~ ~s|data-block-type="compaction"|
      assert html =~ "Conversation compacted"
    end

    @tag feature: "ai_session_detail",
         scenario: "Pre-compaction and meta entries render as raw entries"
    test "renders compact_boundary, summary, and queue-operation meta entries", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      entries = [
        %{
          "type" => "user",
          "uuid" => "u1",
          "sessionId" => "s1",
          "message" => %{"role" => "user", "content" => "pre-compaction question"}
        },
        %{
          "type" => "system",
          "subtype" => "compact_boundary",
          "uuid" => "sys1",
          "compactMetadata" => %{"trigger" => "auto", "preCompactionTokenCount" => 12_345}
        },
        %{
          "type" => "summary",
          "uuid" => "sum1",
          "summary" => "A concise summary of prior work."
        },
        %{
          "type" => "queue-operation",
          "uuid" => "q1",
          "operation" => "enqueue",
          "timestamp" => "2026-04-16T00:00:00Z"
        },
        %{
          "type" => "assistant",
          "uuid" => "a1",
          "sessionId" => "s1",
          "message" => %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "post-compaction reply"}]
          }
        }
      ]

      FakeHistory.stub_raw(ai.claude_session_id, {:ok, entries})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      html = render(view)

      assert html =~ "pre-compaction question"
      assert html =~ "post-compaction reply"
      assert has_element?(view, ~s|[data-meta-kind="compact_boundary"]|)
      assert has_element?(view, ~s|[data-meta-kind="summary"]|)
      assert has_element?(view, ~s|[data-meta-kind="queue_operation"]|)
      assert html =~ "A concise summary of prior work."
      assert html =~ "12345"
    end

    @tag feature: "ai_session_detail",
         scenario: "Unknown block types render via an inspect fallback"
    test "unknown block struct renders through the inspect fallback without crashing",
         %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      messages = [
        assistant_message([
          %{__struct__: NotARealBlock, foo: :bar}
        ])
      ]

      FakeHistory.stub(ai.claude_session_id, {:ok, messages})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      html = render(view)
      assert html =~ ~s|data-block-type="unknown"|
      assert html =~ "NotARealBlock"
    end
  end

  describe "assistant usage chip" do
    defp assistant_message_with_usage(content_blocks, usage) do
      %SessionMessage{
        type: :assistant,
        uuid: Ecto.UUID.generate(),
        session_id: "test-session",
        message: %{content: content_blocks, usage: usage},
        parent_tool_use_id: nil
      }
    end

    @tag feature: "ai_session_detail",
         scenario: "Assistant message renders a token usage chip"
    test "renders usage chip with input and output token counts", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      usage = ClaudeCode.Usage.parse(%{"input_tokens" => 123, "output_tokens" => 45})

      messages = [
        assistant_message_with_usage(
          [%TextBlock{type: "text", text: "hello"}],
          usage
        )
      ]

      FakeHistory.stub(ai.claude_session_id, {:ok, messages})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      assert has_element?(view, ~s|[data-message-role="assistant"] [data-usage]|)
      assert has_element?(view, "[data-usage-in]", "in 123")
      assert has_element?(view, "[data-usage-out]", "out 45")
      refute has_element?(view, "[data-usage-cache]")
    end

    @tag feature: "ai_session_detail",
         scenario: "Assistant usage chip shows cache tokens when present"
    test "includes cache read and cache creation counts when non-zero", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      usage =
        ClaudeCode.Usage.parse(%{
          "input_tokens" => 10,
          "output_tokens" => 20,
          "cache_read_input_tokens" => 7,
          "cache_creation_input_tokens" => 3
        })

      messages = [
        assistant_message_with_usage(
          [%TextBlock{type: "text", text: "hi"}],
          usage
        )
      ]

      FakeHistory.stub(ai.claude_session_id, {:ok, messages})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      assert has_element?(view, "[data-usage-cache]", "cache 7/3")
    end

    @tag feature: "ai_session_detail",
         scenario: "Assistant message without a usage map renders no chip"
    test "renders no chip when usage is absent", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)

      messages = [assistant_message([%TextBlock{type: "text", text: "no usage"}])]

      FakeHistory.stub(ai.claude_session_id, {:ok, messages})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      refute has_element?(view, ~s|[data-message-role="assistant"] [data-usage]|)
    end
  end

  describe "usage totals strip" do
    defp insert_system_message_with_usage(ai, ws, raw) do
      {:ok, msg} =
        AI.create_message(ai.id, %{
          role: :system,
          content: "ok",
          workflow_session_id: ws.id,
          raw_response: raw
        })

      msg
    end

    defp usage_raw(input, output, opts) do
      %{
        usage: %{
          input_tokens: input,
          output_tokens: output,
          cache_read_input_tokens: Keyword.get(opts, :cache_read, 0),
          cache_creation_input_tokens: Keyword.get(opts, :cache_creation, 0)
        },
        total_cost_usd: Keyword.get(opts, :cost, 0.0),
        duration_ms: Keyword.get(opts, :duration, 0.0)
      }
    end

    @tag feature: "ai_session_detail",
         scenario: "Header shows aggregated token and cost totals across turns"
    test "aggregates input/output tokens and cost from all system messages", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)
      FakeHistory.stub(ai.claude_session_id, {:ok, []})

      insert_system_message_with_usage(ai, ws, usage_raw(100, 50, cost: 0.002))
      insert_system_message_with_usage(ai, ws, usage_raw(40, 10, cost: 0.001))

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      assert has_element?(view, "#ai-session-usage-totals")
      assert has_element?(view, "[data-totals-turns]", "2 turns")
      assert has_element?(view, "[data-totals-in]", "in 140")
      assert has_element?(view, "[data-totals-out]", "out 60")
      assert has_element?(view, "[data-totals-cost]", "$0.0030")
    end

    @tag feature: "ai_session_detail",
         scenario: "Totals strip hides when no turns have recorded usage yet"
    test "omits totals strip when no messages have recorded usage", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)
      FakeHistory.stub(ai.claude_session_id, {:ok, []})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")

      refute has_element?(view, "#ai-session-usage-totals")
    end

    @tag feature: "ai_session_detail",
         scenario: "Totals strip updates live when a new turn is recorded"
    test "refreshes totals when a new system message is broadcast", %{conn: conn} do
      ws = create_session()
      ai = create_ai_session(ws)
      FakeHistory.stub(ai.claude_session_id, {:ok, []})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai.id}")
      refute has_element?(view, "#ai-session-usage-totals")

      insert_system_message_with_usage(ai, ws, usage_raw(10, 5, cost: 0.0005))

      assert has_element?(view, "#ai-session-usage-totals")
      assert has_element?(view, "[data-totals-in]", "in 10")
      assert has_element?(view, "[data-totals-out]", "out 5")
      assert has_element?(view, "[data-totals-cost]", "$0.0005")
    end
  end
end
