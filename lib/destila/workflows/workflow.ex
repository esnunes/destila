defmodule Destila.Workflows.Workflow do
  @moduledoc """
  Behaviour and `use` macro for workflow modules.

  Workflows are defined as an ordered list of `AISessionGroup` structs. Each
  group owns the AI-session-level system prompt (via its `skills`) and tool
  scope (`allowed_tools`), and contains one or more ordered `Phase` structs.

  The `__using__` macro derives `phases/0` by flattening `groups/0`, and
  provides default implementations of `total_phases/0`, `phase_name/1`, and
  `phase_columns/0` so existing consumers keep working unchanged.

  ## Usage

      defmodule MyApp.Workflows.MyWorkflow do
        use Destila.Workflows.Workflow

        alias Destila.Workflows.{AISessionGroup, Phase}

        def groups do
          [
            %AISessionGroup{
              name: "Main",
              skills: ["code_quality"],
              allowed_tools: ["Read", "Write"],
              phases: [
                %Phase{name: "Step One", initial_prompt: &step_one_prompt/1},
                %Phase{name: "Step Two", initial_prompt: &step_two_prompt/1}
              ]
            }
          ]
        end

        def label, do: "My Workflow"
        def description, do: "Does something"
        def icon, do: "hero-bolt"
        def icon_class, do: "text-primary"
        def default_title, do: "New Thing"
        def completion_message, do: "Done!"
      end
  """

  @type group_definition :: %Destila.Workflows.AISessionGroup{}
  @type phase_definition :: %Destila.Workflows.Phase{}

  @callback groups() :: [group_definition()]
  @callback label() :: String.t()
  @callback description() :: String.t()
  @callback icon() :: String.t()
  @callback icon_class() :: String.t()
  @callback default_title() :: String.t()
  @callback completion_message() :: String.t()
  @callback creation_label() :: String.t()
  @callback source_metadata_key() :: String.t() | nil

  defmacro __using__(_opts) do
    quote do
      @behaviour Destila.Workflows.Workflow

      def phases, do: Enum.flat_map(groups(), & &1.phases)

      def total_phases, do: length(phases())

      def phase_name(phase) when is_integer(phase) do
        case Enum.at(phases(), phase - 1) do
          %Destila.Workflows.Phase{name: name} -> name
          nil -> nil
        end
      end

      def phase_name(_), do: nil

      def phase_columns do
        columns =
          1..total_phases()
          |> Enum.map(fn n -> {n, phase_name(n)} end)
          |> Enum.reject(fn {_, name} -> is_nil(name) end)

        columns ++ [{:done, "Done"}]
      end

      defoverridable phases: 0, total_phases: 0, phase_name: 1, phase_columns: 0
    end
  end
end
