defmodule Destila.Workflows.AISessionGroup do
  @moduledoc """
  Groups phases that share a single underlying AI session.

  A group's `skills` are assembled into the ClaudeCode SDK `:system_prompt` at
  session start, and its `allowed_tools` are passed as `:allowed_tools`. When a
  workflow advances into a phase whose group differs from the previous phase's
  group, the runtime stops the current `ClaudeSession` and starts a new one —
  carrying forward the worktree path.

  Because the SDK retains the original system prompt across a resumed session,
  `:skills` and `:allowed_tools` apply only to newly started groups.
  """

  @enforce_keys [:name, :phases]
  defstruct [:name, :phases, skills: [], allowed_tools: []]
end
