defmodule Destila.Agent.ToolHandlers do
  @moduledoc """
  Dispatch table for the four MCP tools the new agent path exposes.

  Each handler receives the parsed `arguments` map and the current
  `SessionServer` state, and returns `{reply, new_state}` where `reply`
  is `{:ok, result}` or `{:error, reason}`.
  """

  alias Destila.Agent.Tools

  @handlers %{
    "session" => Tools.SessionTool,
    "mcp__destila__session" => Tools.SessionTool,
    "ask_user_question" => Tools.AskUserQuestionTool,
    "mcp__destila__ask_user_question" => Tools.AskUserQuestionTool,
    "service" => Tools.ServiceTool,
    "mcp__destila__service" => Tools.ServiceTool,
    "exports_read" => Tools.ExportsReadTool,
    "mcp__destila__exports_read" => Tools.ExportsReadTool
  }

  @doc """
  Look up the handler by tool name and invoke it. Used by `SessionServer`.
  """
  def dispatch(name, arguments, state) do
    case Map.get(@handlers, name) do
      nil ->
        {{:error, :unknown_tool}, state}

      module ->
        module.execute(arguments, state)
    end
  end

  @doc """
  Return the JSON Schema list used for `tools/list`. Hard-coded here to keep
  the agent path's tool surface independent of the chat path's macro-driven
  definitions in `Destila.AI.Tools`.
  """
  def schemas do
    [
      %{
        "name" => "session",
        "description" =>
          "Signal a phase transition or export metadata. Use action=phase_complete to auto-advance, action=suggest_phase_complete to ask the user, action=export to store a key/value.",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["action"],
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["suggest_phase_complete", "phase_complete", "export"]
            },
            "message" => %{"type" => "string"},
            "key" => %{"type" => "string"},
            "value" => %{"type" => "string"},
            "type" => %{"type" => "string", "enum" => ["text", "markdown", "file"]}
          }
        }
      },
      %{
        "name" => "ask_user_question",
        "description" =>
          "Present structured questions to the user with selectable options. Returns immediately; the user's answer is delivered out-of-band.",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["questions"],
          "properties" => %{
            "questions" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "required" => ["title", "question", "multi_select", "options"],
                "properties" => %{
                  "title" => %{"type" => "string"},
                  "question" => %{"type" => "string"},
                  "multi_select" => %{"type" => "boolean"},
                  "options" => %{
                    "type" => "array",
                    "items" => %{
                      "type" => "object",
                      "required" => ["label", "description"],
                      "properties" => %{
                        "label" => %{"type" => "string"},
                        "description" => %{"type" => "string"}
                      }
                    }
                  }
                }
              }
            }
          }
        }
      },
      %{
        "name" => "service",
        "description" =>
          "Manage the project's development service lifecycle (start/stop/restart/status).",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["action"],
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["start", "stop", "restart", "status"]
            }
          }
        }
      },
      %{
        "name" => "exports_read",
        "description" => "Read all exports recorded in this session (including prior phases).",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    ]
  end
end
