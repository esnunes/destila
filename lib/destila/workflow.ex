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
  @callback session_strategy(integer()) ::
              :resume | :new | {:resume, keyword()} | {:new, keyword()}

  @doc """
  Returns the action to perform when entering a phase.

  Return values:
  - `{:enqueue, query}` — enqueue the AI worker with the given query
  - `:await_input` — wait for user input (interactive phase)
  """
  @callback phase_start_action(workflow_session :: map(), phase_number :: integer()) ::
              {:enqueue, String.t()} | :await_input

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

      def phase_start_action(workflow_session, phase_number) do
        case Enum.at(phases(), phase_number - 1) do
          {_mod, opts} ->
            non_interactive = Keyword.get(opts, :non_interactive, false)

            case {non_interactive, Keyword.get(opts, :system_prompt)} do
              {true, prompt_fn} when not is_nil(prompt_fn) ->
                {:enqueue, prompt_fn.(workflow_session)}

              _ ->
                :await_input
            end

          nil ->
            :await_input
        end
      end

      defoverridable total_phases: 0,
                     phase_name: 1,
                     phase_columns: 0,
                     session_strategy: 1,
                     phase_start_action: 2
    end
  end
end
