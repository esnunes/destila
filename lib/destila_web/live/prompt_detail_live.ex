defmodule DestilaWeb.PromptDetailLive do
  use DestilaWeb, :live_view

  import DestilaWeb.ChatComponents
  import DestilaWeb.BoardComponents, only: [workflow_badge: 1, progress_indicator: 1]

  alias Destila.Workflows.ChoreTaskPhases

  def mount(%{"id" => id}, session, socket) do
    prompt = Destila.Prompts.get_prompt(id)

    if prompt do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
      end

      messages = Destila.Messages.list_messages(id)

      # If no messages yet, start the workflow by adding the first system message
      messages =
        if messages == [] do
          start_workflow(prompt)
          Destila.Messages.list_messages(id)
        else
          messages
        end

      current_step = current_step_info(messages, prompt)

      {:ok,
       socket
       |> assign(:current_user, session["current_user"])
       |> assign(:prompt, prompt)
       |> assign(:project, lookup_project(prompt))
       |> assign(:messages, messages)
       |> assign(:current_step, current_step)
       |> assign(:editing_title, false)
       |> assign(:question_answers, %{})
       |> assign(:page_title, prompt.title)}
    else
      {:ok,
       socket
       |> assign(:current_user, session["current_user"])
       |> put_flash(:error, "Prompt not found")
       |> push_navigate(to: ~p"/crafting")}
    end
  end

  # Text input — branches between static and AI-driven workflows
  def handle_event("send_text", %{"content" => content}, socket) when content != "" do
    if ai_workflow?(socket.assigns.prompt) do
      handle_ai_message(socket, content)
    else
      handle_static_response(socket, content, nil)
    end
  end

  def handle_event("send_text", _params, socket), do: {:noreply, socket}

  # Single select
  def handle_event("select_single", %{"label" => label}, socket) do
    if ai_workflow?(socket.assigns.prompt) do
      handle_ai_message(socket, label)
    else
      handle_static_response(socket, label, [label])
    end
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

      if ai_workflow?(socket.assigns.prompt) do
        handle_ai_message(socket, content)
      else
        handle_static_response(socket, content, all_selected)
      end
    end
  end

  # Answer a single question in a multi-question set (single select)
  def handle_event("answer_question", %{"index" => idx_str, "answer" => answer}, socket)
      when answer != "" do
    case Integer.parse(idx_str) do
      {idx, _} ->
        answers = Map.put(socket.assigns.question_answers, idx, answer)
        {:noreply, assign(socket, :question_answers, answers)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("answer_question", _params, socket) do
    {:noreply, socket}
  end

  # Answer a multi-select question
  def handle_event("confirm_multi_answer", params, socket) do
    case Integer.parse(params["index"] || "") do
      {idx, _} ->
        confirm_multi_answer(socket, idx, params)

      :error ->
        {:noreply, socket}
    end
  end

  # Submit all answered questions
  def handle_event("submit_all_answers", _params, socket) do
    questions = socket.assigns.current_step.questions
    answers = socket.assigns.question_answers

    response_parts =
      questions
      |> Enum.with_index()
      |> Enum.map(fn {q, idx} ->
        value = answers[idx] || ""
        "**#{q.title}**: #{value}"
      end)

    content = Enum.join(response_parts, "\n")
    socket = assign(socket, :question_answers, %{})
    handle_ai_message(socket, content)
  end

  # Retry failed Phase 0 setup — enqueue both workers so whichever failed gets retried
  # (idempotent steps skip automatically)
  def handle_event("retry_setup", _params, socket) do
    prompt = socket.assigns.prompt

    if prompt.project_id do
      %{"prompt_id" => prompt.id}
      |> Destila.Workers.SetupWorker.new()
      |> Oban.insert()
    end

    if prompt.title_generating do
      workflow_type = to_string(prompt.workflow_type)
      # Re-enqueue title generation with a placeholder idea (title gen is idempotent)
      %{"prompt_id" => prompt.id, "workflow_type" => workflow_type, "idea" => ""}
      |> Destila.Workers.TitleGenerationWorker.new()
      |> Oban.insert()
    end

    {:noreply, refresh_state(socket)}
  end

  # Mock file upload (static workflows only)
  def handle_event("mock_upload", _params, socket) do
    handle_static_response(socket, "Uploaded: mockup-screenshot.png", nil)
  end

  # Title editing
  def handle_event("edit_title", _params, socket) do
    {:noreply, assign(socket, editing_title: true)}
  end

  def handle_event("save_title", %{"title" => title}, socket) do
    title = if title == "", do: socket.assigns.prompt.title, else: title

    {:ok, prompt} =
      Destila.Prompts.update_prompt(socket.assigns.prompt, %{title: title})

    {:noreply,
     socket
     |> assign(:prompt, prompt)
     |> assign(:editing_title, false)
     |> assign(:page_title, title)}
  end

  # Phase advance confirmation (AI workflows)
  def handle_event("confirm_advance", _params, socket) do
    prompt = socket.assigns.prompt
    next_phase = prompt.steps_completed + 1

    if next_phase > prompt.steps_total do
      {:noreply, socket}
    else
      # Advance phase
      {:ok, _} =
        Destila.Prompts.update_prompt(prompt, %{
          steps_completed: next_phase,
          phase_status: :generating
        })

      # Trigger AI response for the new phase via Oban
      updated_prompt = Destila.Prompts.get_prompt!(prompt.id)
      phase_prompt = ChoreTaskPhases.system_prompt(next_phase, updated_prompt)

      %{"prompt_id" => prompt.id, "phase" => next_phase, "query" => phase_prompt}
      |> Destila.Workers.AiQueryWorker.new()
      |> Oban.insert()

      {:noreply, refresh_state(socket)}
    end
  end

  # Decline phase advance (AI workflows)
  def handle_event("decline_advance", _params, socket) do
    Destila.Prompts.update_prompt(socket.assigns.prompt, %{phase_status: :conversing})
    {:noreply, refresh_state(socket)}
  end

  # Mark as done (AI workflows, Phase 4)
  def handle_event("mark_done", _params, socket) do
    prompt = socket.assigns.prompt

    {:ok, _} =
      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: Destila.Workflows.completion_message(:chore_task),
        phase: prompt.steps_completed
      })

    Destila.Prompts.update_prompt(prompt, %{
      steps_completed: prompt.steps_total,
      column: :done,
      phase_status: nil
    })

    {:noreply, refresh_state(socket)}
  end

  # PubSub handlers — re-read from DB for consistency
  def handle_info({:prompt_updated, updated_prompt}, socket) do
    if updated_prompt.id == socket.assigns.prompt.id do
      {:noreply, refresh_state(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:message_added, message}, socket) do
    if message.prompt_id == socket.assigns.prompt.id do
      {:noreply, refresh_state(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private helpers ---

  defp confirm_multi_answer(socket, idx, params) do
    selected = Map.get(params, "selected", [])
    other = Map.get(params, "other", "")

    all_selected =
      if other != "", do: selected ++ [other], else: selected

    if all_selected == [] do
      {:noreply, put_flash(socket, :error, "Please select at least one option")}
    else
      value = Enum.join(all_selected, ", ")
      answers = Map.put(socket.assigns.question_answers, idx, value)
      {:noreply, assign(socket, :question_answers, answers)}
    end
  end

  # --- Static workflow response handling (unchanged logic) ---

  defp handle_static_response(socket, content, selected) do
    prompt = socket.assigns.prompt
    messages = socket.assigns.messages
    current_step = current_step_number(messages)

    # Add user message
    {:ok, _} =
      Destila.Messages.create_message(prompt.id, %{
        role: :user,
        content: content,
        selected: selected,
        phase: current_step
      })

    # Advance workflow
    workflow_steps = Destila.Workflows.steps(prompt.workflow_type)
    next_step_num = current_step + 1
    total = Destila.Workflows.total_steps(prompt.workflow_type)

    if next_step_num <= total do
      # Add next system message
      next_step = Enum.at(workflow_steps, next_step_num - 1)

      {:ok, _} =
        Destila.Messages.create_message(prompt.id, %{
          role: :system,
          content: next_step.content,
          phase: next_step.step
        })

      # Update progress
      Destila.Prompts.update_prompt(prompt, %{steps_completed: current_step})
    else
      # Workflow complete
      {:ok, _} =
        Destila.Messages.create_message(prompt.id, %{
          role: :system,
          content: Destila.Workflows.completion_message(prompt.workflow_type),
          phase: next_step_num
        })

      Destila.Prompts.update_prompt(prompt, %{
        steps_completed: total,
        column: :done
      })
    end

    {:noreply, refresh_state(socket)}
  end

  # --- AI-driven workflow response handling ---

  defp handle_ai_message(socket, content) do
    prompt = socket.assigns.prompt

    # Prevent sending while AI is generating
    if prompt.phase_status in [:setup, :generating] do
      {:noreply, socket}
    else
      phase = prompt.steps_completed

      # Add user message
      {:ok, _} =
        Destila.Messages.create_message(prompt.id, %{
          role: :user,
          content: content,
          selected: nil,
          phase: phase
        })

      # Set generating status
      Destila.Prompts.update_prompt(prompt, %{phase_status: :generating})

      # Enqueue AI query as an Oban job
      %{"prompt_id" => prompt.id, "phase" => phase, "query" => content}
      |> Destila.Workers.AiQueryWorker.new()
      |> Oban.insert()

      {:noreply, refresh_state(socket)}
    end
  end

  # --- Helpers ---

  defp ai_workflow?(%{workflow_type: :chore_task}), do: true
  defp ai_workflow?(_), do: false

  defp lookup_project(prompt) do
    if prompt.project_id, do: Destila.Projects.get_project(prompt.project_id)
  end

  defp start_workflow(prompt) do
    steps = Destila.Workflows.steps(prompt.workflow_type)
    first = List.first(steps)

    {:ok, _} =
      Destila.Messages.create_message(prompt.id, %{
        role: :system,
        content: first.content,
        phase: 1
      })
  end

  defp current_step_number(messages) do
    messages
    |> Enum.filter(&(&1.role == :user))
    |> length()
    |> Kernel.+(1)
  end

  defp current_step_info(messages, prompt) do
    if ai_workflow?(prompt) do
      ai_step_info(prompt, messages)
    else
      static_step_info(messages, prompt)
    end
  end

  defp ai_step_info(prompt, messages) do
    total = prompt.steps_total
    completed = prompt.steps_completed

    cond do
      completed >= total && prompt.column == :done ->
        %{input_type: nil, options: nil, questions: [], completed: true}

      prompt.phase_status == :setup ->
        %{input_type: nil, options: nil, questions: [], completed: false}

      prompt.phase_status == :advance_suggested ->
        %{input_type: nil, options: nil, questions: [], completed: false}

      prompt.phase_status == :generating ->
        %{input_type: :text, options: nil, questions: [], completed: false}

      true ->
        last_system =
          messages
          |> Enum.filter(&(&1.role == :system))
          |> List.last()

        if last_system do
          processed = Destila.Messages.process(last_system, prompt)

          %{
            input_type: processed.input_type,
            options: processed.options,
            questions: processed.questions,
            completed: false
          }
        else
          %{input_type: :text, options: nil, questions: [], completed: false}
        end
    end
  end

  defp static_step_info(messages, prompt) do
    last_system = messages |> Enum.filter(&(&1.role == :system)) |> List.last()
    total = Destila.Workflows.total_steps(prompt.workflow_type)
    completed = prompt.steps_completed

    cond do
      completed >= total ->
        %{input_type: nil, options: nil, questions: [], completed: true}

      last_system ->
        processed = Destila.Messages.process(last_system, prompt)

        %{
          input_type: processed.input_type,
          options: processed.options,
          questions: [],
          completed: false
        }

      true ->
        %{input_type: :text, options: nil, questions: [], completed: false}
    end
  end

  defp refresh_state(socket) do
    prompt = Destila.Prompts.get_prompt!(socket.assigns.prompt.id)
    messages = Destila.Messages.list_messages(prompt.id)
    current_step = current_step_info(messages, prompt)

    # Reset question answers when questions change
    socket =
      if current_step.questions != socket.assigns.current_step.questions do
        assign(socket, :question_answers, %{})
      else
        socket
      end

    socket
    |> assign(:prompt, prompt)
    |> assign(:messages, messages)
    |> assign(:current_step, current_step)
    |> assign(:page_title, prompt.title)
  end

  defp split_phase0(messages) do
    {phase0, rest} = Enum.split_with(messages, &(&1.phase == 0))

    # Deduplicate: keep only the latest message per setup_step
    deduped =
      phase0
      |> Enum.reverse()
      |> Enum.uniq_by(fn msg ->
        (msg.raw_response && msg.raw_response["setup_step"]) || msg.id
      end)
      |> Enum.reverse()

    {deduped, rest}
  end

  defp has_failed_step?(phase0_messages) do
    Enum.any?(phase0_messages, fn msg ->
      msg.raw_response && msg.raw_response["status"] == "failed"
    end)
  end

  defp setup_step_item(assigns) do
    status = assigns.message.raw_response && assigns.message.raw_response["status"]

    assigns = assign(assigns, :status, status)

    ~H"""
    <div class="flex items-center gap-3 text-sm pl-2">
      <%= cond do %>
        <% @status == "completed" -> %>
          <.icon name="hero-check-circle-solid" class="size-4 text-success shrink-0" />
        <% @status == "in_progress" -> %>
          <span class="loading loading-spinner loading-xs shrink-0" />
        <% @status == "failed" -> %>
          <.icon name="hero-x-circle-solid" class="size-4 text-error shrink-0" />
        <% true -> %>
          <.icon name="hero-information-circle-solid" class="size-4 text-base-content/40 shrink-0" />
      <% end %>
      <span class={[
        "flex-1",
        @status == "completed" && "text-base-content/60",
        @status == "in_progress" && "text-base-content/80",
        @status == "failed" && "text-error"
      ]}>
        {@message.content}
      </span>
      <button
        :if={@status == "failed"}
        phx-click="retry_setup"
        class="btn btn-xs btn-outline btn-error"
      >
        Retry
      </button>
    </div>
    """
  end

  defp phase_name(phase), do: ChoreTaskPhases.phase_name(phase)

  defp phase_groups(messages, current_phase) do
    groups =
      messages
      |> Enum.chunk_by(& &1.phase)
      |> Enum.map(fn group -> {List.first(group).phase, group} end)

    # Ensure the current phase has a group even if no messages yet
    if Enum.any?(groups, fn {phase, _} -> phase == current_phase end) do
      groups
    else
      groups ++ [{current_phase, []}]
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} page_title={@page_title}>
      <div class="flex flex-col h-screen">
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
                    class={[
                      "text-lg font-bold truncate transition-colors",
                      if(@prompt.title_generating,
                        do: "animate-pulse text-base-content/50",
                        else: "cursor-pointer hover:text-primary"
                      )
                    ]}
                    phx-click={if(!@prompt.title_generating, do: "edit_title")}
                  >
                    {@prompt.title}
                  </h1>
                  <button
                    :if={!@prompt.title_generating}
                    phx-click="edit_title"
                    class="cursor-pointer"
                  >
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
                  <span :if={@project} class="text-xs text-base-content/40">
                    <.link
                      navigate={~p"/projects"}
                      class="hover:text-base-content/60 transition-colors"
                    >
                      {@project.name}
                    </.link>
                    <span :if={@project.git_repo_url} class="ml-1">
                      ({@project.git_repo_url})
                    </span>
                  </span>
                </div>
              </div>
            </div>

            <div class="flex items-center gap-3 ml-4">
              <div class="flex items-center gap-2">
                <div class="w-24">
                  <.progress_indicator
                    completed={@prompt.steps_completed}
                    total={@prompt.steps_total}
                  />
                </div>
                <%= if ai_workflow?(@prompt) do %>
                  <span class="text-xs text-base-content/40">
                    Phase {max(@prompt.steps_completed, 1)}/{@prompt.steps_total}
                    <span :if={phase_name(max(@prompt.steps_completed, 1))} class="hidden sm:inline">
                      — {phase_name(max(@prompt.steps_completed, 1))}
                    </span>
                  </span>
                <% else %>
                  <span class="text-xs text-base-content/40">
                    {@prompt.steps_completed}/{@prompt.steps_total}
                  </span>
                <% end %>
              </div>

              <%!-- Mark as Done button for AI workflows in Phase 4 --%>
              <button
                :if={
                  ai_workflow?(@prompt) && @prompt.steps_completed >= 4 &&
                    @prompt.column != :done
                }
                phx-click="mark_done"
                class="btn btn-success btn-sm"
              >
                <.icon name="hero-check-micro" class="size-4" /> Mark as Done
              </button>
            </div>
          </div>
        </div>

        <%!-- Chat area --%>
        <div class="flex-1 overflow-y-auto px-6 py-6" id="chat-messages" phx-hook="ScrollBottom">
          <div class="max-w-2xl mx-auto">
            <%= if ai_workflow?(@prompt) do %>
              <% current_phase = max(@prompt.steps_completed, 1) %>
              <% {phase0_messages, conversation_messages} = split_phase0(@messages) %>

              <%!-- Phase 0 — Setup --%>
              <%= if phase0_messages != [] || @prompt.phase_status == :setup do %>
                <details
                  class="phase-section first-phase"
                  open={@prompt.phase_status == :setup}
                >
                  <summary class="flex items-center gap-3 my-6 cursor-pointer group list-none">
                    <div class="flex-1 h-px bg-base-300" />
                    <span class="flex items-center gap-1.5 text-xs font-medium text-base-content/40 uppercase tracking-wide group-hover:text-base-content/60 transition-colors">
                      Phase 0 — Setup
                      <.icon
                        name="hero-chevron-down-micro"
                        class="size-3 phase-chevron"
                      />
                    </span>
                    <div class="flex-1 h-px bg-base-300" />
                  </summary>
                  <div class="space-y-2 py-2">
                    <.setup_step_item
                      :for={msg <- phase0_messages}
                      message={msg}
                    />
                    <div
                      :if={@prompt.phase_status == :setup && !has_failed_step?(phase0_messages)}
                      class="flex items-center gap-3 text-sm text-base-content/50 pl-2"
                    >
                      <span class="loading loading-spinner loading-xs" />
                      <span>Setting up...</span>
                    </div>
                  </div>
                </details>
              <% end %>

              <%!-- Conversation phases (1+) --%>
              <%= for {phase, group} <- phase_groups(conversation_messages, current_phase) do %>
                <details
                  class={["phase-section", phase == 1 && phase0_messages == [] && "first-phase"]}
                  open={phase >= current_phase}
                >
                  <summary class="flex items-center gap-3 my-6 cursor-pointer group list-none">
                    <div class="flex-1 h-px bg-base-300" />
                    <span class="flex items-center gap-1.5 text-xs font-medium text-base-content/40 uppercase tracking-wide group-hover:text-base-content/60 transition-colors">
                      Phase {phase} — {phase_name(phase)}
                      <.icon
                        name="hero-chevron-down-micro"
                        class="size-3 phase-chevron"
                      />
                    </span>
                    <div class="flex-1 h-px bg-base-300" />
                  </summary>
                  <.chat_message :for={msg <- group} message={msg} prompt={@prompt} />
                  <.chat_typing_indicator :if={
                    phase == current_phase && @prompt.phase_status == :generating
                  } />
                </details>
              <% end %>
            <% else %>
              <.chat_message :for={message <- @messages} message={message} prompt={@prompt} />
              <.chat_typing_indicator :if={@prompt.phase_status == :generating} />
            <% end %>

            <%!-- Inline structured options (inside chat flow) --%>
            <div
              :if={
                !@current_step.completed &&
                  @current_step.input_type in [:single_select, :multi_select]
              }
              class="ml-11 mb-4"
            >
              <.chat_input
                input_type={@current_step.input_type}
                options={@current_step.options}
                inline
              />
            </div>

            <%!-- Inline multi-question form --%>
            <div
              :if={
                !@current_step.completed &&
                  @current_step.input_type == :questions
              }
              class="ml-11 mb-4"
            >
              <.multi_question_input questions={@current_step.questions} answers={@question_answers} />
            </div>
          </div>
        </div>

        <%!-- Text input (fixed at bottom, only for text input type) --%>
        <div
          :if={
            !@current_step.completed &&
              @current_step.input_type not in [:single_select, :multi_select, :questions]
          }
          class="max-w-2xl mx-auto w-full"
        >
          <.chat_input
            input_type={@current_step.input_type}
            options={@current_step.options}
            disabled={
              ai_workflow?(@prompt) &&
                @prompt.phase_status in [:setup, :generating, :advance_suggested]
            }
          />
        </div>

        <%!-- Completed state --%>
        <div
          :if={@current_step.completed}
          class="border-t border-base-300 bg-base-200/50 px-4 py-3"
        >
          <p class="text-sm text-base-content/50 flex items-center justify-center gap-2">
            <.icon name="hero-check-circle-solid" class="size-4 text-success" />
            <span>
              Workflow complete
            </span>
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
