defmodule Destila.AI.ResponseProcessorTest do
  use ExUnit.Case, async: true

  alias Destila.AI.ResponseProcessor

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
end
