defmodule Destila.Agent.Workflow.Phase do
  @moduledoc """
  A single phase inside a `Destila.Agent.Workflow` definition.

  Carries the system prompt, the kickoff prompt that Destila pushes
  (embedded) or surfaces for paste (external), and the agent command
  Destila runs in embedded mode.
  """

  @enforce_keys [:name, :system_prompt, :kickoff_prompt, :agent_command]
  defstruct [:name, :system_prompt, :kickoff_prompt, :agent_command]

  @type t :: %__MODULE__{
          name: String.t(),
          system_prompt: String.t(),
          kickoff_prompt: String.t(),
          agent_command: [String.t()]
        }
end
