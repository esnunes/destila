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
        content: "What type of feature is this? This helps us structure the prompt appropriately.",
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
        content:
          "Which areas of the codebase will be affected? Select all that apply.",
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
        content:
          "What's the primary tech stack for this project?",
        input_type: :single_select,
        options: [
          %{label: "Web App", description: "Full-stack web application with frontend and backend"},
          %{label: "Mobile App", description: "iOS, Android, or cross-platform mobile application"},
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

  def total_steps(:feature_request), do: 4
  def total_steps(:project), do: 3

  def completion_message(:feature_request) do
    "Your feature request prompt is ready! I've gathered all the details needed to create a comprehensive, actionable prompt for your coding agent. You can now move this to the Implementation Board to start building."
  end

  def completion_message(:project) do
    "Your project prompt is complete! I've captured your project vision, tech stack, and scope. This prompt is ready to guide a coding agent through the initial implementation. Move it to the Implementation Board when you're ready."
  end
end
