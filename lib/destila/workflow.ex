defmodule Destila.Workflow do
  @moduledoc """
  Behaviour and `use` macro for workflow modules.

  Provides default implementations for `total_phases/0`, `phase_name/1`,
  and `phase_columns/0` derived from the `phases/0` callback, eliminating
  boilerplate across workflow modules.

  ## Usage

      defmodule MyApp.Workflows.MyWorkflow do
        use Destila.Workflow

        def phases do
          [
            {MyPhaseComponent, name: "Step One"},
            {MyPhaseComponent, name: "Step Two"}
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

  @type phase_definition :: {module(), keyword()}

  @callback phases() :: [phase_definition()]
  @callback label() :: String.t()
  @callback description() :: String.t()
  @callback icon() :: String.t()
  @callback icon_class() :: String.t()
  @callback default_title() :: String.t()
  @callback completion_message() :: String.t()
  @doc """
  Returns the creation form configuration for this workflow.

  The tuple contains:
  - `source_metadata_key` — the exported metadata key to search for source sessions,
    or `nil` if no source selection is needed
  - `label` — the label for the text input field (e.g., "Idea", "Prompt")
  - `dest_metadata_key` — the metadata key under which the user's input is stored
  """
  @callback creation_config() ::
              {source_metadata_key :: String.t() | nil, label :: String.t(),
               dest_metadata_key :: String.t()}

  @callback session_strategy(integer()) ::
              :resume | :new | {:resume, keyword()} | {:new, keyword()}

  @doc """
  Called when a phase is entered. Performs any startup work (e.g. enqueuing
  a worker) and returns the resulting status.

  Return values:
  - `:processing` — work was enqueued, phase is actively processing
  - `:awaiting_input` — waiting for user/external input
  """
  @callback phase_start_action(workflow_session :: map(), phase_number :: integer()) ::
              :processing | :awaiting_input

  @doc """
  Called when a phase receives an update (user input, AI response, etc.).
  Performs the work (e.g. saving messages, enqueuing workers) and returns
  the resulting status.

  Return values:
  - `:processing` — work was enqueued, phase is actively processing
  - `:awaiting_input` — waiting for user/external input
  - `:phase_complete` — phase is done, auto-advance to next
  - `:suggest_phase_complete` — suggest completion, wait for user confirmation
  """
  @callback phase_update_action(
              workflow_session :: map(),
              phase_number :: integer(),
              params :: map()
            ) :: :processing | :awaiting_input | :phase_complete | :suggest_phase_complete

  defmacro __using__(_opts) do
    quote do
      @behaviour Destila.Workflow

      def total_phases, do: length(phases())

      def phase_name(phase) when is_integer(phase) do
        case Enum.at(phases(), phase - 1) do
          {_mod, opts} -> Keyword.get(opts, :name)
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

      def session_strategy(_phase), do: :resume

      defoverridable total_phases: 0, phase_name: 1, phase_columns: 0, session_strategy: 1
    end
  end
end
