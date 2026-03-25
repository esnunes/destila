defmodule Destila.Workflows.PromptNewProjectWorkflow do
  @moduledoc """
  Defines the New Project workflow — a scripted multi-step form
  that captures project idea, tech stack, and v1 scope.
  """

  def steps do
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

  def total_steps, do: 3

  @phase_names %{
    1 => "Project Idea",
    2 => "Tech Stack",
    3 => "V1 Features"
  }

  def phase_name(phase) when is_map_key(@phase_names, phase) do
    @phase_names[phase]
  end

  def phase_name(_phase), do: nil

  def phase_columns do
    columns =
      1..total_steps()
      |> Enum.map(fn n -> {n, phase_name(n)} end)
      |> Enum.reject(fn {_, name} -> is_nil(name) end)

    columns ++ [{:done, "Done"}]
  end

  def default_title, do: "New Project"

  def completion_message do
    "Your project prompt is complete! I've captured your project vision, tech stack, and scope. This prompt is ready to guide a coding agent through the initial implementation."
  end
end
