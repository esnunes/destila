defmodule Destila.Deps do
  @moduledoc """
  Tracks external CLI tools that Destila requires on the user's `PATH`.

  Exposes a single `check/0` function that returns per-tool availability.
  The list is derived from `@required_tools` and wraps `System.find_executable/1`
  per tool — no caching, no process state.
  """

  @required_tools [
    %{
      name: "claude",
      display_name: "Claude Code CLI",
      purpose: "Runs AI sessions inside Destila.",
      install_command: "npm install -g @anthropic-ai/claude-code",
      docs_url: "https://docs.claude.com/en/docs/claude-code/overview"
    },
    %{
      name: "tmux",
      display_name: "tmux",
      purpose: "Terminal multiplexer used to host long-running workflow terminals.",
      install_command: "brew install tmux",
      docs_url: "https://github.com/tmux/tmux/wiki/Installing"
    },
    %{
      name: "ffmpeg",
      display_name: "ffmpeg",
      purpose: "Media processing for workflow video artifacts.",
      install_command: "brew install ffmpeg",
      docs_url: "https://ffmpeg.org/download.html"
    },
    %{
      name: "agent-browser",
      display_name: "agent-browser",
      purpose: "Headless browser automation used by the browser testing skills.",
      install_command: "npm install -g @every/agent-browser",
      docs_url: "https://www.npmjs.com/package/@every/agent-browser"
    }
  ]

  @doc """
  Returns the list of required tools with each one's availability on `PATH`.

  Each map includes `:name`, `:display_name`, `:purpose`, `:install_command`,
  `:docs_url`, and `:available?`.
  """
  def check do
    Enum.map(@required_tools, fn tool ->
      Map.put(tool, :available?, System.find_executable(tool.name) != nil)
    end)
  end
end
