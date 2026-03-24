defmodule Destila.Workflows do
  @moduledoc """
  Defines workflow scripts for each workflow type.
  Each step has an AI message with an input_type and optional options.
  """

  def steps(:prompt_new_project) do
    [
      %{
        step: 1,
        content:
          "Tell me about your project idea. What are you building and who is it for? The more context you provide, the better the resulting prompt will be.",
        input_type: :text,
        options: nil
      },
      %{
        step: 2,
        content: "What's the primary tech stack for this project?",
        input_type: :single_select,
        options: [
          %{
            label: "Web App",
            description: "Full-stack web application with frontend and backend"
          },
          %{
            label: "Mobile App",
            description: "iOS, Android, or cross-platform mobile application"
          },
          %{label: "CLI Tool", description: "Command-line interface tool or utility"},
          %{label: "Library", description: "Reusable package or library for other developers"}
        ]
      },
      %{
        step: 3,
        content:
          "Which features should be in scope for v1? Select all that apply to your initial release.",
        input_type: :multi_select,
        options: [
          %{label: "Auth", description: "User authentication and authorization"},
          %{label: "Dashboard", description: "Main overview or analytics view"},
          %{label: "API", description: "REST or GraphQL API endpoints"},
          %{label: "Admin Panel", description: "Administrative management interface"},
          %{label: "Notifications", description: "Email, push, or in-app notifications"}
        ]
      }
    ]
  end

  def steps(:prompt_chore_task) do
    [
      %{
        step: 1,
        content:
          "Let's work on your task. Describe what you need done — the more context you provide, the better I can help clarify and refine the approach.",
        input_type: :text,
        options: nil
      }
    ]
  end

  def steps(:implement_generic_prompt) do
    [
      %{
        step: 1,
        content:
          "Describe what you want to implement. Provide as much context as possible about the desired outcome.",
        input_type: :text,
        options: nil
      }
    ]
  end

  def total_steps(:prompt_new_project), do: 3
  def total_steps(:prompt_chore_task), do: 4
  def total_steps(:implement_generic_prompt), do: 1

  @doc """
  Returns the human-readable phase name for a workflow type and phase number.
  """
  def phase_name(:prompt_chore_task, phase),
    do: Destila.Workflows.ChoreTaskPhases.phase_name(phase)

  def phase_name(:prompt_new_project, 1), do: "Project Idea"
  def phase_name(:prompt_new_project, 2), do: "Tech Stack"
  def phase_name(:prompt_new_project, 3), do: "V1 Features"

  def phase_name(:implement_generic_prompt, 1), do: "Implementation"

  def phase_name(_type, _phase), do: nil

  @doc """
  Returns the list of {phase_number, phase_name} column definitions for a workflow type,
  including a final {:done, "Done"} column.
  """
  def phase_columns(workflow_type) do
    # prompt_chore_task starts at phase 0 (Setup — git/worktree init) while
    # static workflows have no phase 0.
    range =
      case workflow_type do
        :prompt_chore_task -> 0..total_steps(workflow_type)
        _ -> 1..total_steps(workflow_type)
      end

    columns =
      range
      |> Enum.map(fn n -> {n, phase_name(workflow_type, n)} end)
      |> Enum.reject(fn {_, name} -> is_nil(name) end)

    columns ++ [{:done, "Done"}]
  end

  def completion_message(:prompt_new_project) do
    "Your project prompt is complete! I've captured your project vision, tech stack, and scope. This prompt is ready to guide a coding agent through the initial implementation."
  end

  def completion_message(:prompt_chore_task) do
    "Your implementation prompt is ready! The task has been clarified, the technical approach defined, and Gherkin scenarios reviewed."
  end

  def completion_message(:implement_generic_prompt) do
    "Your implementation session is complete."
  end
end
