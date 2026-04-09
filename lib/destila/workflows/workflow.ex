defmodule Destila.Workflows.Workflow do
  @moduledoc """
  Behaviour and `use` macro for workflow modules.

  Provides default implementations for `total_phases/0`, `phase_name/1`,
  and `phase_columns/0` derived from the `phases/0` callback, eliminating
  boilerplate across workflow modules.

  ## Usage

      defmodule MyApp.Workflows.MyWorkflow do
        use Destila.Workflows.Workflow

        alias Destila.Workflows.Phase

        def phases do
          [
            %Phase{name: "Step One", system_prompt: &step_one_prompt/1},
            %Phase{name: "Step Two", system_prompt: &step_two_prompt/1}
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

  @type phase_definition :: %Destila.Workflows.Phase{}

  @callback phases() :: [phase_definition()]
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

      defoverridable total_phases: 0, phase_name: 1, phase_columns: 0
    end
  end
end
