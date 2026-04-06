defmodule Destila.Workflows.Phase do
  @moduledoc """
  Struct describing a single workflow phase.

  Replaces the `{module, keyword()}` tuples previously used in `phases/0`.
  """

  @enforce_keys [:name, :system_prompt]
  defstruct [
    :name,
    :system_prompt,
    :message_type,
    non_interactive: false,
    allowed_tools: [],
    session_strategy: :resume
  ]
end
