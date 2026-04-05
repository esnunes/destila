defmodule Destila.Workflow.Phase do
  @moduledoc """
  Struct describing a single workflow phase.

  Replaces the `{module, keyword()}` tuples previously used in `phases/0`.
  """

  @enforce_keys [:name, :system_prompt]
  defstruct [
    :name,
    :system_prompt,
    :message_type,
    skippable: false,
    final: false,
    non_interactive: false,
    allowed_tools: []
  ]
end
