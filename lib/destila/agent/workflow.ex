defmodule Destila.Agent.Workflow do
  @moduledoc """
  Defines a workflow loaded from `priv/workflows/*.yaml`.

  A workflow is an ordered list of phases. Each phase carries the system prompt,
  the kickoff prompt that Destila pushes (embedded) or surfaces for paste
  (external), and the agent command Destila runs in embedded mode.
  """

  defmodule Phase do
    @enforce_keys [:name, :system_prompt, :kickoff_prompt, :agent_command]
    defstruct [:name, :system_prompt, :kickoff_prompt, :agent_command]

    @type t :: %__MODULE__{
            name: String.t(),
            system_prompt: String.t(),
            kickoff_prompt: String.t(),
            agent_command: [String.t()]
          }
  end

  @enforce_keys [:name, :phases]
  defstruct [:name, :phases]

  @type t :: %__MODULE__{
          name: String.t(),
          phases: [Phase.t()]
        }
end
