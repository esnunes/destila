defmodule Destila.Workflows do
  @moduledoc """
  Defines mocked chat workflow scripts for each workflow type.
  Each step has an AI message with an input_type and optional options.
  """

  def steps(:feature_request) do
    [
      %{
        step: 1,
        content:
          "Let's start crafting your feature request. What problem are you trying to solve? Describe the current pain point or gap in functionality.",
        input_type: :text,
        options: nil
      },
      %{
        step: 2,
        content:
          "What type of feature is this? This helps us structure the prompt appropriately.",
        input_type: :single_select,
        options: [
          %{label: "UI Enhancement", description: "Visual or interaction improvements"},
          %{label: "API Change", description: "New or modified API endpoints"},
          %{label: "Performance", description: "Speed, efficiency, or resource optimization"},
          %{label: "Infrastructure", description: "Deployment, CI/CD, or tooling changes"}
        ]
      },
      %{
        step: 3,
        content: "Which areas of the codebase will be affected? Select all that apply.",
        input_type: :multi_select,
        options: [
          %{label: "Frontend", description: "UI components, styles, client-side logic"},
          %{label: "Backend", description: "Server-side logic, services, controllers"},
          %{label: "Database", description: "Schema changes, migrations, queries"},
          %{label: "DevOps", description: "Infrastructure, deployment, monitoring"}
        ]
      },
      %{
        step: 4,
        content:
          "Do you have any mockups, screenshots, or reference materials that would help illustrate the desired outcome?",
        input_type: :file_upload,
        options: nil
      }
    ]
  end

  def steps(:project) do
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

  def steps(:chore_task) do
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

  def total_steps(:feature_request), do: 4
  def total_steps(:project), do: 3
  def total_steps(:chore_task), do: 4

  @doc """
  Returns the human-readable phase name for a workflow type and phase number.
  """
  def phase_name(:chore_task, phase), do: Destila.Workflows.ChoreTaskPhases.phase_name(phase)

  def phase_name(:feature_request, 1), do: "Problem"
  def phase_name(:feature_request, 2), do: "Feature Type"
  def phase_name(:feature_request, 3), do: "Affected Areas"
  def phase_name(:feature_request, 4), do: "Mockups"

  def phase_name(:project, 1), do: "Project Idea"
  def phase_name(:project, 2), do: "Tech Stack"
  def phase_name(:project, 3), do: "V1 Features"

  def phase_name(_type, _phase), do: nil

  @doc """
  Returns the list of {phase_number, phase_name} column definitions for a workflow type,
  including a final {:done, "Done"} column.
  """
  def phase_columns(workflow_type) do
    # chore_task starts at phase 0 (Setup — git/worktree init) while
    # static workflows (feature_request, project) have no phase 0.
    range =
      case workflow_type do
        :chore_task -> 0..total_steps(workflow_type)
        _ -> 1..total_steps(workflow_type)
      end

    columns =
      range
      |> Enum.map(fn n -> {n, phase_name(workflow_type, n)} end)
      |> Enum.reject(fn {_, name} -> is_nil(name) end)

    columns ++ [{:done, "Done"}]
  end

  def completion_message(:feature_request) do
    "Your feature request prompt is ready! I've gathered all the details needed to create a comprehensive, actionable prompt for your coding agent. You can now move this to the Implementation Board to start building."
  end

  def completion_message(:project) do
    "Your project prompt is complete! I've captured your project vision, tech stack, and scope. This prompt is ready to guide a coding agent through the initial implementation. Move it to the Implementation Board when you're ready."
  end

  def completion_message(:chore_task) do
    "Your implementation prompt is ready! The task has been clarified, the technical approach defined, and Gherkin scenarios reviewed. Move it to the Implementation Board when you're ready."
  end
end
