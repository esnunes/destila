defmodule Destila.Workflows.CodeChatWorkflow do
  @moduledoc """
  Defines the Code Chat workflow — a free-form, open-ended chat experience
  with AI that has full access to code tools and write permissions.

  Single phase: Chat — stays open until the user manually marks it as done.
  No phase transitions, no autonomous steps, no structured pipeline.
  """

  use Destila.Workflows.Workflow

  alias Destila.Workflows.Phase

  @chat_tools [
    "Read",
    "Write",
    "Edit",
    "Bash",
    "Glob",
    "Grep",
    "WebFetch",
    "Skill",
    "mcp__destila__ask_user_question",
    "mcp__destila__session"
  ]

  def phases do
    [
      %Phase{
        name: "Chat",
        system_prompt: &chat_prompt/1,
        allowed_tools: @chat_tools,
        skills: ["code_quality"]
      }
    ]
  end

  def creation_label, do: "Prompt"
  def source_metadata_key, do: nil

  def default_title, do: "New Chat"

  def label, do: "Code Chat"
  def description, do: "Chat with AI with full access to tools and write permissions"
  def icon, do: "hero-chat-bubble-left-right"
  def icon_class, do: "text-accent"

  def completion_message, do: "Chat session complete."

  # --- AI System Prompt ---

  defp chat_prompt(workflow_session) do
    user_prompt = workflow_session.user_prompt

    user_context =
      if user_prompt && user_prompt != "" do
        "\n\nThe user's initial message:\n#{user_prompt}"
      else
        ""
      end

    """
    You are a general-purpose coding assistant. Help the user with any coding \
    task — reading, writing, editing files, running commands, searching the \
    codebase, debugging, refactoring, or answering questions about code.

    You have full access to code tools and write permissions. Use them freely \
    to assist the user.

    Guidelines:
    - Be direct and helpful
    - Use tools proactively when they would help answer the user's question
    - When making changes, explain what you did and why
    - Ask clarifying questions when the request is ambiguous

    IMPORTANT: Never call `mcp__destila__session` with `suggest_phase_complete` or \
    `phase_complete`. The user controls when this session ends via the UI.
    """ <> user_context
  end
end
