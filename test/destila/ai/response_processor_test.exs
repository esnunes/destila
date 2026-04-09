defmodule Destila.AI.ResponseProcessorTest do
  use ExUnit.Case, async: true

  alias Destila.AI.ResponseProcessor
  alias Destila.AI.Message

  describe "extract_export_actions/1" do
    test "extracts type from export actions (atom keys)" do
      result = %{
        mcp_tool_uses: [
          %{
            name: "mcp__destila__session",
            input: %{action: "export", key: "doc", value: "# Title", type: "markdown"}
          }
        ]
      }

      assert [%{key: "doc", value: "# Title", type: "markdown"}] =
               ResponseProcessor.extract_export_actions(result)
    end

    test "extracts type from export actions (string keys)" do
      result = %{
        "mcp_tool_uses" => [
          %{
            "name" => "mcp__destila__session",
            "input" => %{
              "action" => "export",
              "key" => "doc",
              "value" => "# Title",
              "type" => "markdown"
            }
          }
        ]
      }

      assert [%{key: "doc", value: "# Title", type: "markdown"}] =
               ResponseProcessor.extract_export_actions(result)
    end

    test "type is nil when omitted" do
      result = %{
        mcp_tool_uses: [
          %{
            name: "mcp__destila__session",
            input: %{action: "export", key: "doc", value: "plain text"}
          }
        ]
      }

      assert [%{key: "doc", value: "plain text", type: nil}] =
               ResponseProcessor.extract_export_actions(result)
    end

    test "extracts multiple exports with different types" do
      result = %{
        mcp_tool_uses: [
          %{
            name: "mcp__destila__session",
            input: %{action: "export", key: "summary", value: "text", type: "text"}
          },
          %{
            name: "mcp__destila__session",
            input: %{action: "export", key: "doc", value: "# MD", type: "markdown"}
          }
        ]
      }

      exports = ResponseProcessor.extract_export_actions(result)
      assert length(exports) == 2
      assert Enum.at(exports, 0).type == "text"
      assert Enum.at(exports, 1).type == "markdown"
    end

    test "ignores non-export session actions" do
      result = %{
        mcp_tool_uses: [
          %{
            name: "mcp__destila__session",
            input: %{action: "phase_complete", message: "done"}
          }
        ]
      }

      assert [] = ResponseProcessor.extract_export_actions(result)
    end
  end

  describe "process_message/2 exports" do
    test "includes exports from AI response with export tool calls" do
      msg = %Message{
        id: Ecto.UUID.generate(),
        role: :system,
        phase: 1,
        content: "Here's your prompt.",
        raw_response: %{
          "mcp_tool_uses" => [
            %{
              "name" => "mcp__destila__session",
              "input" => %{
                "action" => "export",
                "key" => "generated_prompt",
                "value" => "# Prompt",
                "type" => "markdown"
              }
            }
          ]
        },
        inserted_at: DateTime.utc_now()
      }

      ws = %{workflow_type: :brainstorm_idea}
      processed = ResponseProcessor.process_message(msg, ws)

      assert [%{key: "generated_prompt", value: "# Prompt", type: "markdown"}] = processed.exports
    end

    test "exports is empty list for user messages" do
      msg = %Message{
        id: Ecto.UUID.generate(),
        role: :user,
        phase: 1,
        content: "Hello",
        inserted_at: DateTime.utc_now()
      }

      processed = ResponseProcessor.process_message(msg, %{})
      assert processed.exports == []
    end

    test "exports is empty list for messages without export tool calls" do
      msg = %Message{
        id: Ecto.UUID.generate(),
        role: :system,
        phase: 1,
        content: "Just text",
        raw_response: %{"mcp_tool_uses" => []},
        inserted_at: DateTime.utc_now()
      }

      ws = %{workflow_type: :brainstorm_idea}
      processed = ResponseProcessor.process_message(msg, ws)
      assert processed.exports == []
    end

    test "multiple exports from a single message" do
      msg = %Message{
        id: Ecto.UUID.generate(),
        role: :system,
        phase: 1,
        content: "Exported two things.",
        raw_response: %{
          "mcp_tool_uses" => [
            %{
              "name" => "mcp__destila__session",
              "input" => %{
                "action" => "export",
                "key" => "summary",
                "value" => "A summary",
                "type" => "text"
              }
            },
            %{
              "name" => "mcp__destila__session",
              "input" => %{
                "action" => "export",
                "key" => "doc",
                "value" => "# Doc",
                "type" => "markdown"
              }
            }
          ]
        },
        inserted_at: DateTime.utc_now()
      }

      ws = %{workflow_type: :brainstorm_idea}
      processed = ResponseProcessor.process_message(msg, ws)

      assert length(processed.exports) == 2
      assert Enum.at(processed.exports, 0).key == "summary"
      assert Enum.at(processed.exports, 1).key == "doc"
    end
  end

  describe "process_message/2 message_type" do
    test "does not derive :generated_prompt from phase config" do
      msg = %Message{
        id: Ecto.UUID.generate(),
        role: :system,
        phase: 4,
        content: "Final prompt content",
        raw_response: %{"mcp_tool_uses" => []},
        inserted_at: DateTime.utc_now()
      }

      # Phase 4 of brainstorm_idea was previously :generated_prompt
      ws = %{workflow_type: :brainstorm_idea}
      processed = ResponseProcessor.process_message(msg, ws)

      assert processed.message_type == nil
    end
  end
end
