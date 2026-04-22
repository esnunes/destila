defmodule Destila.Workflows.Phase do
  @moduledoc """
  Struct describing a single workflow phase.

  Phases live inside an `AISessionGroup`. The group owns the SDK-level system
  prompt (its `skills`) and tool scope (`allowed_tools`). A phase contributes
  an `initial_prompt` used as the kickoff message body and optional per-phase
  `skills` that are rendered as an additional section in the kickoff body.
  """

  @enforce_keys [:name, :initial_prompt]
  defstruct [
    :name,
    :initial_prompt,
    non_interactive: false,
    skills: []
  ]
end
