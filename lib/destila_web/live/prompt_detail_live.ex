defmodule DestilaWeb.PromptDetailLive do
  use DestilaWeb, :live_view

  import DestilaWeb.ChatComponents
  import DestilaWeb.BoardComponents, only: [workflow_badge: 1, progress_indicator: 1]

  alias Destila.Workflows.ChoreTaskPhases

  def mount(%{"id" => id}, session, socket) do
    prompt = Destila.Store.get_prompt(id)

    if prompt do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
      end

      messages = Destila.Store.list_messages(id)

      # If no messages yet, start the workflow by adding the first system message
      messages =
        if messages == [] do
          start_workflow(prompt)
          Destila.Store.list_messages(id)
        else
          messages
        end

      # For AI workflows, ensure session is alive and trigger initial response if needed
      socket =
        if ai_workflow?(prompt) && connected?(socket) do
          ensure_ai_session(socket, prompt, messages)
        else
          socket
        end

      current_step = current_step_info(messages, prompt)

      {:ok,
       socket
       |> assign(:current_user, session["current_user"])
       |> assign(:prompt, Destila.Store.get_prompt(id) || prompt)
       |> assign(:messages, Destila.Store.list_messages(id))
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
    idx = String.to_integer(idx_str)
    answers = Map.put(socket.assigns.question_answers, idx, answer)
    {:noreply, assign(socket, :question_answers, answers)}
  end

  def handle_event("answer_question", _params, socket) do
    {:noreply, socket}
  end

  # Answer a multi-select question
  def handle_event("confirm_multi_answer", params, socket) do
    idx = String.to_integer(params["index"])
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

  # Phase advance confirmation (AI workflows)
  def handle_event("confirm_advance", _params, socket) do
    prompt = socket.assigns.prompt
    next_phase = prompt.steps_completed + 1

    if next_phase > prompt.steps_total do
      {:noreply, socket}
    else
      # Insert phase divider message
      phase_name = ChoreTaskPhases.phase_name(next_phase)

      Destila.Store.add_message(prompt.id, %{
        role: :system,
        content: "Phase #{next_phase} — #{phase_name}",
        input_type: nil,
        step: next_phase,
        message_type: :phase_divider
      })

      # Advance phase
      Destila.Store.update_prompt(prompt.id, %{
        steps_completed: next_phase,
        phase_status: :generating
      })

      # Trigger AI response for the new phase — send phase system prompt only
      # (session already has full conversation history)
      updated_prompt = Destila.Store.get_prompt(prompt.id)
      phase_prompt = ChoreTaskPhases.system_prompt(next_phase, updated_prompt)
      spawn_ai_query(prompt.id, next_phase, phase_prompt)

      {:noreply, refresh_state(socket)}
    end
  end

  # Decline phase advance (AI workflows)
  def handle_event("decline_advance", _params, socket) do
    Destila.Store.update_prompt(socket.assigns.prompt.id, %{phase_status: :conversing})
    {:noreply, refresh_state(socket)}
  end

  # Mark as done (AI workflows, Phase 4)
  def handle_event("mark_done", _params, socket) do
    prompt = socket.assigns.prompt

    Destila.Store.add_message(prompt.id, %{
      role: :system,
      content: Destila.Workflows.completion_message(:chore_task),
      input_type: nil,
      step: prompt.steps_completed,
      message_type: nil
    })

    Destila.Store.update_prompt(prompt.id, %{
      steps_completed: prompt.steps_total,
      column: :done,
      phase_status: nil
    })

    {:noreply, refresh_state(socket)}
  end

  # PubSub handlers
  def handle_info({:prompt_updated, updated_prompt}, socket) do
    if updated_prompt.id == socket.assigns.prompt.id do
      messages = Destila.Store.list_messages(updated_prompt.id)
      current_step = current_step_info(messages, updated_prompt)

      {:noreply,
       socket
       |> assign(:prompt, updated_prompt)
       |> assign(:messages, messages)
       |> assign(:current_step, current_step)
       |> assign(:page_title, updated_prompt.title)}
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

  # --- Static workflow response handling (unchanged logic) ---

  defp handle_static_response(socket, content, selected) do
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

    {:noreply, refresh_state(socket)}
  end

  # --- AI-driven workflow response handling ---

  defp handle_ai_message(socket, content) do
    prompt = socket.assigns.prompt

    # Prevent sending while AI is generating
    if prompt[:phase_status] == :generating do
      {:noreply, socket}
    else
      phase = prompt.steps_completed

      # Add user message
      Destila.Store.add_message(prompt.id, %{
        role: :user,
        content: content,
        selected: nil,
        step: phase
      })

      # Set generating status
      Destila.Store.update_prompt(prompt.id, %{phase_status: :generating})

      # Spawn async AI query — pass user's message directly (session has context)
      spawn_ai_query(prompt.id, phase, content)

      {:noreply, refresh_state(socket)}
    end
  end

  # query_text: the text to send to the AI session.
  # - For user messages: the user's message text (session already has conversation history)
  # - For phase transitions: the phase system prompt (to set new AI instructions)
  # - For session resumption: system prompt + full conversation context
  defp spawn_ai_query(prompt_id, phase, query_text) do
    Task.Supervisor.start_child(Destila.TaskSupervisor, fn ->
      prompt = Destila.Store.get_prompt(prompt_id)
      session = prompt[:ai_session]

      if session && Process.alive?(session) do
        case Destila.AI.Session.query(session, query_text) do
          {:ok, result} ->
            response_text =
              if result.text != nil and result.text != "" do
                result.text
              else
                result.result || ""
              end

            {content, message_type, new_phase_status} = parse_ai_response(response_text)

            # In the final phase, normal AI responses are generated prompts
            message_type =
              if phase == prompt.steps_total and message_type == nil,
                do: :generated_prompt,
                else: message_type

            questions = extract_questions_from_tool_uses(result[:mcp_tool_uses])

            # Use question texts from tool if AI text is empty/generic
            content =
              if questions != [] and (content == "" or content == "Waiting for your answer.") do
                questions |> Enum.map(& &1.question) |> Enum.join("\n\n")
              else
                content
              end

            # Derive input_type from questions for backwards compat
            {input_type, options} =
              case questions do
                [] -> {:text, nil}
                [q] -> {q.input_type, q.options}
                _ -> {:questions, nil}
              end

            Destila.Store.add_message(prompt_id, %{
              role: :system,
              content: content,
              input_type: input_type,
              options: options,
              questions: questions,
              step: phase,
              message_type: message_type
            })

            # Handle auto-skip (Phase 3)
            if message_type == :skip_phase do
              handle_skip_phase(prompt_id, phase)
            else
              Destila.Store.update_prompt(prompt_id, %{phase_status: new_phase_status})
            end

          {:error, _} ->
            Destila.Store.add_message(prompt_id, %{
              role: :system,
              content: "Something went wrong. Please try sending your message again.",
              input_type: :text,
              step: phase
            })

            Destila.Store.update_prompt(prompt_id, %{phase_status: :conversing})
        end
      else
        # Session is dead — try to restart
        restart_ai_session(prompt_id)

        Destila.Store.add_message(prompt_id, %{
          role: :system,
          content: "Session was refreshed. Please send your message again.",
          input_type: :text,
          step: phase
        })

        Destila.Store.update_prompt(prompt_id, %{phase_status: :conversing})
      end
    end)
  end

  defp handle_skip_phase(prompt_id, current_phase) do
    next_phase = current_phase + 1
    phase_name = ChoreTaskPhases.phase_name(next_phase)

    # Insert skip notice
    Destila.Store.add_message(prompt_id, %{
      role: :system,
      content: "Phase #{next_phase} — #{phase_name}",
      input_type: nil,
      step: next_phase,
      message_type: :phase_divider
    })

    # Advance to next phase
    Destila.Store.update_prompt(prompt_id, %{
      steps_completed: next_phase,
      phase_status: :generating
    })

    # Trigger AI for the next phase — send phase system prompt only
    prompt = Destila.Store.get_prompt(prompt_id)
    phase_prompt = ChoreTaskPhases.system_prompt(next_phase, prompt)
    spawn_ai_query(prompt_id, next_phase, phase_prompt)
  end

  defp restart_ai_session(prompt_id) do
    case Destila.AI.Session.start_link(timeout_ms: :timer.minutes(15)) do
      {:ok, session} ->
        Destila.Store.update_prompt(prompt_id, %{ai_session: session})

      {:error, _} ->
        :ok
    end
  end

  defp ensure_ai_session(socket, prompt, messages) do
    session = prompt[:ai_session]

    cond do
      session && Process.alive?(session) ->
        # Session alive — check if we need to trigger initial AI response
        # (e.g., user just created the prompt and we have their idea but no AI response yet)
        last_msg = List.last(messages)

        if last_msg && last_msg.role == :user && prompt[:phase_status] != :generating do
          Destila.Store.update_prompt(prompt.id, %{phase_status: :generating})
          # Session is alive, just send the user's latest message
          spawn_ai_query(prompt.id, prompt.steps_completed, last_msg.content)
        end

        socket

      true ->
        # Session dead or nil — restart with full context
        case Destila.AI.Session.start_link(timeout_ms: :timer.minutes(15)) do
          {:ok, new_session} ->
            Destila.Store.update_prompt(prompt.id, %{ai_session: new_session})

            # If there's a pending user message, trigger AI response with full context
            last_msg = List.last(messages)

            if last_msg && last_msg.role == :user do
              phase = prompt.steps_completed
              system_prompt = ChoreTaskPhases.system_prompt(phase, prompt)
              context = ChoreTaskPhases.build_conversation_context(messages)
              query = system_prompt <> "\n\n" <> context

              Destila.Store.update_prompt(prompt.id, %{phase_status: :generating})
              spawn_ai_query(prompt.id, phase, query)
            end

            socket

          {:error, _} ->
            put_flash(socket, :error, "Failed to start AI session")
        end
    end
  end

  defp parse_ai_response(text) do
    cond do
      String.contains?(text, "<<SKIP_PHASE>>") ->
        content = String.replace(text, "<<SKIP_PHASE>>", "") |> String.trim()
        {content, :skip_phase, :conversing}

      String.contains?(text, "<<READY_TO_ADVANCE>>") ->
        content = String.replace(text, "<<READY_TO_ADVANCE>>", "") |> String.trim()
        {content, :phase_advance, :advance_suggested}

      true ->
        {String.trim(text), nil, :conversing}
    end
  end

  defp extract_questions_from_tool_uses(nil), do: []
  defp extract_questions_from_tool_uses([]), do: []

  defp extract_questions_from_tool_uses(mcp_tool_uses) do
    mcp_tool_uses
    |> Enum.filter(fn tool ->
      tool.name in ["ask_user_question", "mcp__destila__ask_user_question"]
    end)
    |> Enum.flat_map(fn %{input: input} ->
      # Handle both single-question (legacy) and multi-question formats
      questions = input["questions"] || [input]

      Enum.map(questions, fn q ->
        multi_select = q["multi_select"] == true

        %{
          question: q["question"] || "",
          title: q["title"],
          input_type: if(multi_select, do: :multi_select, else: :single_select),
          options:
            (q["options"] || [])
            |> Enum.map(fn opt ->
              %{label: opt["label"] || "", description: opt["description"]}
            end)
        }
      end)
    end)
  end

  # --- Helpers ---

  defp ai_workflow?(%{workflow_type: :chore_task}), do: true
  defp ai_workflow?(_), do: false

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

      prompt[:phase_status] == :advance_suggested ->
        %{input_type: nil, options: nil, questions: [], completed: false}

      prompt[:phase_status] == :generating ->
        %{input_type: :text, options: nil, questions: [], completed: false}

      true ->
        # Use the last system message's input_type, options, and questions
        last_system =
          messages
          |> Enum.filter(&(&1.role == :system && &1[:message_type] not in [:phase_divider]))
          |> List.last()

        input_type = (last_system && last_system[:input_type]) || :text
        options = last_system && last_system[:options]
        questions = (last_system && last_system[:questions]) || []

        %{input_type: input_type, options: options, questions: questions, completed: false}
    end
  end

  defp static_step_info(messages, prompt) do
    last_system = messages |> Enum.filter(&(&1.role == :system)) |> List.last()
    total = Destila.Workflows.total_steps(prompt.workflow_type)
    completed = prompt.steps_completed

    cond do
      completed >= total ->
        %{input_type: nil, options: nil, questions: [], completed: true}

      last_system && last_system.input_type ->
        %{
          input_type: last_system.input_type,
          options: last_system.options,
          questions: [],
          completed: false
        }

      true ->
        %{input_type: :text, options: nil, questions: [], completed: false}
    end
  end

  defp refresh_state(socket) do
    prompt = Destila.Store.get_prompt(socket.assigns.prompt.id)
    messages = Destila.Store.list_messages(prompt.id)
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

  defp phase_name(phase), do: ChoreTaskPhases.phase_name(phase)

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
                      if(@prompt[:title_generating],
                        do: "animate-pulse text-base-content/50",
                        else: "cursor-pointer hover:text-primary"
                      )
                    ]}
                    phx-click={if(!@prompt[:title_generating], do: "edit_title")}
                  >
                    {@prompt.title}
                  </h1>
                  <button
                    :if={!@prompt[:title_generating]}
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
                  <span :if={@prompt.repo_url} class="text-xs text-base-content/40">
                    {@prompt.repo_url}
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
            <.chat_message
              :for={message <- @messages}
              message={message}
              prompt={@prompt}
            />

            <%!-- Typing indicator --%>
            <.chat_typing_indicator :if={@prompt[:phase_status] == :generating} />

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
              ai_workflow?(@prompt) && @prompt[:phase_status] in [:generating, :advance_suggested]
            }
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
