defmodule Destila.Workflows do
  @moduledoc """
  Thin dispatcher that routes workflow operations to the appropriate
  workflow module based on `workflow_type`.
  """

  @workflow_modules %{
    prompt_chore_task: Destila.Workflows.PromptChoreTaskWorkflow,
    prompt_new_project: Destila.Workflows.PromptNewProjectWorkflow,
    implement_generic_prompt: Destila.Workflows.ImplementGenericPromptWorkflow
  }

  @doc """
  Returns the workflow module for a given workflow type.
  """
  def workflow_module(workflow_type) do
    Map.fetch!(@workflow_modules, workflow_type)
  end

  def steps(workflow_type), do: workflow_module(workflow_type).steps()
  def total_steps(workflow_type), do: workflow_module(workflow_type).total_steps()
  def phase_name(workflow_type, phase), do: workflow_module(workflow_type).phase_name(phase)
  def phase_columns(workflow_type), do: workflow_module(workflow_type).phase_columns()
  def completion_message(workflow_type), do: workflow_module(workflow_type).completion_message()

  @doc """
  Returns the session strategy for a given workflow type and phase
  as a normalized `{action, opts}` tuple.

  Defaults to `{:resume, []}` for workflow types that don't define `session_strategy/1`.
  """
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
