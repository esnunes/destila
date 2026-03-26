defmodule Destila.Workflows do
  @moduledoc """
  Thin dispatcher that routes workflow operations to the appropriate
  workflow module based on `workflow_type`.
  """

  @workflow_modules %{
    prompt_chore_task: Destila.Workflows.PromptChoreTaskWorkflow
  }

  def workflow_module(workflow_type) do
    Map.fetch!(@workflow_modules, workflow_type)
  end

  def workflow_types, do: Map.keys(@workflow_modules)

  def workflow_type_metadata do
    Enum.map(@workflow_modules, fn {type, mod} ->
      %{
        type: type,
        label: mod.label(),
        description: mod.description(),
        icon: mod.icon(),
        icon_class: mod.icon_class()
      }
    end)
  end

  def phases(workflow_type), do: workflow_module(workflow_type).phases()
  def total_phases(workflow_type), do: workflow_module(workflow_type).total_phases()
  def phase_name(workflow_type, phase), do: workflow_module(workflow_type).phase_name(phase)
  def phase_columns(workflow_type), do: workflow_module(workflow_type).phase_columns()
  def default_title(workflow_type), do: workflow_module(workflow_type).default_title()
  def completion_message(workflow_type), do: workflow_module(workflow_type).completion_message()

  def session_strategy(workflow_type, phase) do
    module = workflow_module(workflow_type)

    strategy =
      if function_exported?(module, :session_strategy, 1) do
        module.session_strategy(phase)
      else
        :resume
      end

    normalize_strategy(strategy)
  end

  defp normalize_strategy(:resume), do: {:resume, []}
  defp normalize_strategy(:new), do: {:new, []}
  defp normalize_strategy({action, opts}) when action in [:resume, :new], do: {action, opts}
end
