defmodule DestilaWeb.PromptDetailLive do
  use DestilaWeb, :live_view

  import DestilaWeb.ChatComponents
  import DestilaWeb.BoardComponents, only: [workflow_badge: 1, progress_indicator: 1]

  def mount(%{"id" => id}, session, socket) do
    prompt = Destila.Store.get_prompt(id)

    if prompt do
      messages = Destila.Store.list_messages(id)

      # If no messages yet, start the workflow by adding the first system message
      messages =
        if messages == [] do
          start_workflow(prompt)
          Destila.Store.list_messages(id)
        else
          messages
        end

      current_step = current_step_info(messages, prompt)

      {:ok,
       socket
       |> assign(:current_user, session["current_user"])
       |> assign(:prompt, prompt)
       |> assign(:messages, messages)
       |> assign(:current_step, current_step)
       |> assign(:editing_title, false)
       |> assign(:page_title, prompt.title)}
    else
      {:ok,
       socket
       |> assign(:current_user, session["current_user"])
       |> put_flash(:error, "Prompt not found")
       |> push_navigate(to: ~p"/crafting")}
    end
  end

  # Text input
  def handle_event("send_text", %{"content" => content}, socket) when content != "" do
    handle_user_response(socket, content, nil)
  end

  def handle_event("send_text", _params, socket), do: {:noreply, socket}

  # Single select
  def handle_event("select_single", %{"label" => label}, socket) do
    handle_user_response(socket, label, [label])
  end

  # Multi select
  def handle_event("select_multi", params, socket) do
    selected = Map.get(params, "selected", [])
    other = Map.get(params, "other", "")

    all_selected =
      if other != "", do: selected ++ [other], else: selected

    if all_selected == [] do
      {:noreply, put_flash(socket, :error, "Please select at least one option")}
    else
      content = Enum.join(all_selected, ", ")
      handle_user_response(socket, content, all_selected)
    end
  end

  # Mock file upload
  def handle_event("mock_upload", _params, socket) do
    handle_user_response(socket, "Uploaded: mockup-screenshot.png", nil)
  end

  # Title editing
  def handle_event("edit_title", _params, socket) do
    {:noreply, assign(socket, editing_title: true)}
  end

  def handle_event("save_title", %{"title" => title}, socket) do
    title = if title == "", do: socket.assigns.prompt.title, else: title
    prompt = Destila.Store.update_prompt(socket.assigns.prompt.id, %{title: title})

    {:noreply,
     socket
     |> assign(:prompt, prompt)
     |> assign(:editing_title, false)
     |> assign(:page_title, title)}
  end

  # Send to implementation
  def handle_event("send_to_implementation", _params, socket) do
    prompt =
      Destila.Store.update_prompt(socket.assigns.prompt.id, %{
        board: :implementation,
        column: :todo
      })

    {:noreply,
     socket
     |> assign(:prompt, prompt)
     |> put_flash(:info, "Moved to Implementation Board")}
  end

  defp handle_user_response(socket, content, selected) do
    prompt = socket.assigns.prompt
    messages = socket.assigns.messages
    current_step = current_step_number(messages)

    # Add user message
    Destila.Store.add_message(prompt.id, %{
      role: :user,
      content: content,
      selected: selected,
      step: current_step
    })

    # Advance workflow
    workflow_steps = Destila.Workflows.steps(prompt.workflow_type)
    next_step_num = current_step + 1
    total = Destila.Workflows.total_steps(prompt.workflow_type)

    if next_step_num <= total do
      # Add next system message
      next_step = Enum.at(workflow_steps, next_step_num - 1)

      Destila.Store.add_message(prompt.id, %{
        role: :system,
        content: next_step.content,
        input_type: next_step.input_type,
        options: next_step.options,
        step: next_step.step
      })

      # Update progress
      Destila.Store.update_prompt(prompt.id, %{steps_completed: current_step})
    else
      # Workflow complete
      Destila.Store.add_message(prompt.id, %{
        role: :system,
        content: Destila.Workflows.completion_message(prompt.workflow_type),
        input_type: nil,
        step: next_step_num
      })

      Destila.Store.update_prompt(prompt.id, %{
        steps_completed: total,
        column: :done
      })
    end

    # Refresh state
    updated_prompt = Destila.Store.get_prompt(prompt.id)
    updated_messages = Destila.Store.list_messages(prompt.id)
    current_step_info = current_step_info(updated_messages, updated_prompt)

    {:noreply,
     socket
     |> assign(:prompt, updated_prompt)
     |> assign(:messages, updated_messages)
     |> assign(:current_step, current_step_info)}
  end

  defp start_workflow(prompt) do
    steps = Destila.Workflows.steps(prompt.workflow_type)
    first = List.first(steps)

    Destila.Store.add_message(prompt.id, %{
      role: :system,
      content: first.content,
      input_type: first.input_type,
      options: first.options,
      step: first.step
    })
  end

  defp current_step_number(messages) do
    messages
    |> Enum.filter(&(&1.role == :user))
    |> length()
    |> Kernel.+(1)
  end

  defp current_step_info(messages, prompt) do
    last_system = messages |> Enum.filter(&(&1.role == :system)) |> List.last()
    total = Destila.Workflows.total_steps(prompt.workflow_type)
    completed = prompt.steps_completed

    cond do
      completed >= total ->
        %{input_type: nil, options: nil, completed: true}

      last_system && last_system.input_type ->
        %{input_type: last_system.input_type, options: last_system.options, completed: false}

      true ->
        %{input_type: :text, options: nil, completed: false}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="flex flex-col h-[calc(100vh-4rem)]">
        <%!-- Header --%>
        <div class="border-b border-base-300 bg-base-100 px-6 py-4">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-4 flex-1 min-w-0">
              <.link navigate={~p"/crafting"} class="btn btn-ghost btn-sm btn-square">
                <.icon name="hero-arrow-left-micro" class="size-4" />
              </.link>

              <div class="flex-1 min-w-0">
                <div :if={!@editing_title} class="flex items-center gap-2">
                  <h1
                    class="text-lg font-bold truncate cursor-pointer hover:text-primary transition-colors"
                    phx-click="edit_title"
                  >
                    {@prompt.title}
                  </h1>
                  <button phx-click="edit_title" class="cursor-pointer">
                    <.icon name="hero-pencil-micro" class="size-3.5 text-base-content/30" />
                  </button>
                </div>

                <form :if={@editing_title} phx-submit="save_title" class="flex items-center gap-2">
                  <input
                    type="text"
                    name="title"
                    value={@prompt.title}
                    class="input input-bordered input-sm w-full max-w-md"
                    autofocus
                    phx-blur="save_title"
                    phx-value-title={@prompt.title}
                  />
                </form>

                <div class="flex items-center gap-3 mt-1">
                  <.workflow_badge type={@prompt.workflow_type} />
                  <span :if={@prompt.repo_url} class="text-xs text-base-content/40">
                    {@prompt.repo_url}
                  </span>
                </div>
              </div>
            </div>

            <div class="flex items-center gap-3 ml-4">
              <div class="w-32">
                <.progress_indicator
                  completed={@prompt.steps_completed}
                  total={@prompt.steps_total}
                />
              </div>
              <button
                :if={@prompt.column == :done && @prompt.board == :crafting}
                phx-click="send_to_implementation"
                class="btn btn-primary btn-sm"
              >
                <.icon name="hero-rocket-launch-micro" class="size-4" /> Send to Implementation
              </button>
            </div>
          </div>
        </div>

        <%!-- Chat area --%>
        <div class="flex-1 overflow-y-auto px-6 py-6" id="chat-messages" phx-hook="ScrollBottom">
          <div class="max-w-2xl mx-auto">
            <.chat_message :for={message <- @messages} message={message} />
          </div>
        </div>

        <%!-- Input area --%>
        <div :if={!@current_step.completed} class="max-w-2xl mx-auto w-full">
          <.chat_input
            input_type={@current_step.input_type}
            options={@current_step.options}
          />
        </div>

        <%!-- Completed state --%>
        <div
          :if={@current_step.completed}
          class="border-t border-base-300 bg-base-200/50 p-4 text-center"
        >
          <p class="text-sm text-base-content/50">
            Workflow complete
            <span :if={@prompt.board == :crafting && @prompt.column == :done}>
              &mdash; ready to send to Implementation Board
            </span>
            <span :if={@prompt.board == :implementation}>
              &mdash; moved to Implementation Board
            </span>
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
