defmodule Destila.Agent.Workflow do
  @moduledoc """
  Defines a workflow loaded from `priv/workflows/*.yaml`.

  A workflow is an ordered list of `Destila.Agent.Workflow.Phase` structs.
  """

  alias Destila.Agent.Workflow.Phase

  @enforce_keys [:name, :phases]
  defstruct [:name, :phases]

  @type t :: %__MODULE__{
          name: String.t(),
          phases: [Phase.t()]
        }
end
