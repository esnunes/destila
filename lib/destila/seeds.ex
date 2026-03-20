defmodule Destila.Seeds do
  @moduledoc """
  Seeds the in-memory store with example data for the prototype.
  """

  alias Destila.Store

  def seed do
    seed_crafting_board()
    seed_implementation_board()
    seed_chat_messages()
  end

  defp seed_crafting_board do
    # Request column
    insert_prompt(%{
      title: "Add dark mode toggle to settings",
      workflow_type: :feature_request,
      repo_url: "https://github.com/acme/webapp",
      board: :crafting,
      column: :request,
      steps_completed: 0,
      steps_total: 4,
      position: 1
    })

    insert_prompt(%{
      title: "Build onboarding wizard for new users",
      workflow_type: :project,
      repo_url: nil,
      board: :crafting,
      column: :request,
      steps_completed: 0,
      steps_total: 3,
      position: 2
    })

    # Distill column — one with partial chat, one fresh
    insert_prompt(
      %{
        title: "Refactor authentication middleware",
        workflow_type: :feature_request,
        repo_url: "https://github.com/acme/api-server",
        board: :crafting,
        column: :distill,
        steps_completed: 2,
        steps_total: 4,
        position: 3
      },
      :with_partial_chat
    )

    insert_prompt(%{
      title: "CLI tool for database migrations",
      workflow_type: :project,
      repo_url: nil,
      board: :crafting,
      column: :distill,
      steps_completed: 1,
      steps_total: 3,
      position: 4
    })

    insert_prompt(%{
      title: "Fix flaky test in user registration flow",
      workflow_type: :chore_task,
      repo_url: "https://github.com/acme/webapp",
      board: :crafting,
      column: :request,
      steps_completed: 0,
      steps_total: 4,
      position: 6
    })

    insert_prompt(%{
      title: "Refactor payment gateway error handling",
      workflow_type: :chore_task,
      repo_url: "https://github.com/acme/payments",
      board: :crafting,
      column: :distill,
      steps_completed: 1,
      steps_total: 4,
      position: 7
    })

    # Done column
    insert_prompt(%{
      title: "Implement webhook retry logic",
      workflow_type: :feature_request,
      repo_url: "https://github.com/acme/webhooks",
      board: :crafting,
      column: :done,
      steps_completed: 4,
      steps_total: 4,
      position: 5
    })
  end

  defp seed_implementation_board do
    insert_prompt(%{
      title: "Add rate limiting to API gateway",
      workflow_type: :feature_request,
      repo_url: "https://github.com/acme/gateway",
      board: :implementation,
      column: :todo,
      steps_completed: 4,
      steps_total: 4,
      position: 10
    })

    insert_prompt(%{
      title: "Build notification service",
      workflow_type: :project,
      repo_url: "https://github.com/acme/notifications",
      board: :implementation,
      column: :todo,
      steps_completed: 3,
      steps_total: 3,
      position: 11
    })

    insert_prompt(%{
      title: "Migrate user sessions to Redis",
      workflow_type: :feature_request,
      repo_url: "https://github.com/acme/auth",
      board: :implementation,
      column: :in_progress,
      steps_completed: 4,
      steps_total: 4,
      position: 12
    })

    insert_prompt(%{
      title: "GraphQL schema for reporting API",
      workflow_type: :feature_request,
      repo_url: "https://github.com/acme/reports",
      board: :implementation,
      column: :review,
      steps_completed: 4,
      steps_total: 4,
      position: 13
    })

    insert_prompt(%{
      title: "E2E test suite for checkout flow",
      workflow_type: :project,
      repo_url: "https://github.com/acme/store",
      board: :implementation,
      column: :qa,
      steps_completed: 3,
      steps_total: 3,
      position: 14
    })

    insert_prompt(%{
      title: "Search indexing pipeline",
      workflow_type: :project,
      repo_url: "https://github.com/acme/search",
      board: :implementation,
      column: :impl_done,
      steps_completed: 3,
      steps_total: 3,
      position: 15
    })
  end

  defp seed_chat_messages do
    # Find the prompt with partial chat ("Refactor authentication middleware")
    prompts = Store.list_prompts()

    partial_chat_prompt =
      Enum.find(prompts, &(&1.title == "Refactor authentication middleware"))

    if partial_chat_prompt do
      base_time = DateTime.utc_now() |> DateTime.add(-3600, :second)

      # Step 1: System asks, user answers with free text
      Store.add_message(partial_chat_prompt.id, %{
        role: :system,
        content:
          "Let's start crafting your feature request. What problem are you trying to solve? Describe the current pain point or gap in functionality.",
        input_type: :text,
        step: 1,
        created_at: DateTime.add(base_time, 0, :second)
      })

      Store.add_message(partial_chat_prompt.id, %{
        role: :user,
        content:
          "Our current auth middleware is tightly coupled to Express.js and stores session tokens in a way that doesn't meet the new compliance requirements. We need to refactor it to be framework-agnostic and use encrypted, short-lived tokens instead.",
        input_type: nil,
        step: 1,
        created_at: DateTime.add(base_time, 60, :second)
      })

      # Step 2: System asks single-select, user answers
      Store.add_message(partial_chat_prompt.id, %{
        role: :system,
        content:
          "What type of feature is this? This helps us structure the prompt appropriately.",
        input_type: :single_select,
        options: [
          %{label: "UI Enhancement", description: "Visual or interaction improvements"},
          %{label: "API Change", description: "New or modified API endpoints"},
          %{label: "Performance", description: "Speed, efficiency, or resource optimization"},
          %{label: "Infrastructure", description: "Deployment, CI/CD, or tooling changes"}
        ],
        step: 2,
        created_at: DateTime.add(base_time, 120, :second)
      })

      Store.add_message(partial_chat_prompt.id, %{
        role: :user,
        content: "Infrastructure",
        input_type: nil,
        selected: ["Infrastructure"],
        step: 2,
        created_at: DateTime.add(base_time, 180, :second)
      })

      # Step 3: System asks multi-select (this is the current step — user hasn't answered yet)
      Store.add_message(partial_chat_prompt.id, %{
        role: :system,
        content: "Which areas of the codebase will be affected? Select all that apply.",
        input_type: :multi_select,
        options: [
          %{label: "Frontend", description: "UI components, styles, client-side logic"},
          %{label: "Backend", description: "Server-side logic, services, controllers"},
          %{label: "Database", description: "Schema changes, migrations, queries"},
          %{label: "DevOps", description: "Infrastructure, deployment, monitoring"}
        ],
        step: 3,
        created_at: DateTime.add(base_time, 240, :second)
      })
    end
  end

  defp insert_prompt(attrs, :with_partial_chat) do
    insert_prompt(attrs)
  end

  defp insert_prompt(attrs) do
    id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    now = DateTime.utc_now()

    prompt =
      Map.merge(
        %{
          id: id,
          created_at: now,
          updated_at: now
        },
        attrs
      )

    :ets.insert(:destila_store, {{:prompt, id}, prompt})
    prompt
  end
end
