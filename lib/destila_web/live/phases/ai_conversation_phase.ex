defmodule DestilaWeb.Phases.AiConversationPhase do
  @moduledoc """
  LiveComponent for AI conversation phases.

  Fully self-contained: subscribes to PubSub, handles all chat events
  (send_text, select, advance, decline, mark_done), manages its own
  DB writes and worker enqueuing.

  Signals parent only for phase-level changes via:
  - `{:phase_advanced, new_phase}` — phase changed, parent should update chrome
  - `{:workflow_done}` — workflow marked as done

  Opts:
  - `name` — phase display name (required)
  - `system_prompt` — fn/1 returning the system prompt (required)
  - `skippable` — supports phase_complete session tool action (default false)
  - `final` — shows "Mark as Done" instead of advance (default false)
  """

  use DestilaWeb, :live_component

  import DestilaWeb.ChatComponents

  alias Destila.AI
  alias Destila.Workflows
  alias Destila.Workflows

  def mount(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
    end

    {:ok,
     socket
     |> assign(:question_answers, %{})
     |> assign(:initialized, false)}
  end

  def update(assigns, socket) do
    ws = assigns.workflow_session
    phase_number = assigns.phase_number
    opts = assigns.opts

    ai_session = AI.get_ai_session_for_workflow(ws.id)
    messages = if ai_session, do: AI.list_messages(ai_session.id), else: []
    current_step = compute_current_step(ws, messages)

    socket =
      socket
      |> assign(:workflow_session, ws)
      |> assign(:phase_number, phase_number)
      |> assign(:opts, opts)
      |> assign(:ai_session, ai_session)
      |> assign(:messages, messages)
      |> assign(:current_step, current_step)

    socket =
      if !socket.assigns.initialized && connected?(socket) do
        socket
        |> maybe_initialize_ai(ws, ai_session, phase_number, opts)
        |> assign(:initialized, true)
      else
        socket
      end

    {:ok, socket}
  end

  # --- PubSub ---

  def handle_info({:message_added, _msg}, socket) do
    refresh_from_db(socket)
  end

  def handle_info({:workflow_session_updated, updated_ws}, socket) do
    if updated_ws.id == socket.assigns.workflow_session.id do
      refresh_from_db(socket)
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Chat events (targeted via phx-target={@myself}) ---

  def handle_event("send_text", %{"content" => content}, socket) when content != "" do
    ws = socket.assigns.workflow_session
    ai_session = socket.assigns.ai_session

    if ai_session do
      case Workflows.send_user_message(ws.workflow_type, ws, ai_session, content) do
        {:ok, ws} ->
          messages = AI.list_messages(ai_session.id)

          {:noreply,
           socket
           |> assign(:workflow_session, ws)
           |> assign(:messages, messages)
           |> assign(:current_step, compute_current_step(ws, messages))}

        {:error, :generating} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("send_text", _params, socket), do: {:noreply, socket}

  def handle_event("select_single", %{"label" => label}, socket) do
    handle_event("send_text", %{"content" => label}, socket)
  end

  def handle_event("select_multi", params, socket) do
    selected = Map.get(params, "selected", [])
    other = Map.get(params, "other", "")
    all_selected = if other != "", do: selected ++ [other], else: selected

    if all_selected != [] do
      handle_event("send_text", %{"content" => Enum.join(all_selected, ", ")}, socket)
    else
      {:noreply, socket}
    end
  end

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

  def handle_event("answer_question", _params, socket), do: {:noreply, socket}

  def handle_event("confirm_multi_answer", params, socket) do
    case Integer.parse(params["index"] || "") do
      {idx, _} ->
        selected = Map.get(params, "selected", [])
        other = Map.get(params, "other", "")
        all_selected = if other != "", do: selected ++ [other], else: selected

        if all_selected != [] do
          value = Enum.join(all_selected, ", ")
          answers = Map.put(socket.assigns.question_answers, idx, value)
          {:noreply, assign(socket, :question_answers, answers)}
        else
          {:noreply, socket}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("submit_all_answers", _params, socket) do
    ws = socket.assigns.workflow_session
    ai_session = socket.assigns.ai_session
    messages = if ai_session, do: AI.list_messages(ai_session.id), else: []
    last_system = messages |> Enum.filter(&(&1.role == :system)) |> List.last()

    if last_system do
      processed = AI.process_message(last_system, ws)
      answers = socket.assigns.question_answers

      response_parts =
        processed.questions
        |> Enum.with_index()
        |> Enum.map(fn {q, idx} ->
          value = answers[idx] || ""
          "**#{q.title}**: #{value}"
        end)

      content = Enum.join(response_parts, "\n")
      socket = assign(socket, :question_answers, %{})
      handle_event("send_text", %{"content" => content}, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("confirm_advance", _params, socket) do
    ws = socket.assigns.workflow_session

    case Workflows.advance_phase(ws) do
      {:ok, updated_ws} ->
        send(self(), {:phase_advanced, updated_ws.current_phase})

        {:noreply,
         socket
         |> assign(:workflow_session, updated_ws)
         |> assign(:phase_number, updated_ws.current_phase)
         |> assign(:question_answers, %{})
         |> assign(:initialized, false)}

      {:error, :at_boundary} ->
        {:noreply, socket}
    end
  end

  def handle_event("decline_advance", _params, socket) do
    ws = socket.assigns.workflow_session
    {:ok, ws} = Workflows.update_workflow_session(ws, %{phase_status: :conversing})
    {:noreply, assign(socket, :workflow_session, ws)}
  end

  def handle_event("mark_done", _params, socket) do
    {:ok, ws} = Workflows.mark_done(socket.assigns.workflow_session)
    send(self(), :workflow_done)
    {:noreply, assign(socket, :workflow_session, ws)}
  end

  # --- Render ---

  def render(assigns) do
    assigns =
      assigns
      |> assign(:phase_groups, phase_groups(assigns.messages, assigns.phase_number))

    ~H"""
    <div class="flex flex-col h-full">
      <%!-- Scrollable chat area --%>
      <div class="flex-1 min-h-0 overflow-y-auto px-6 py-6" id="chat-messages" phx-hook="ScrollBottom">
        <div class="max-w-2xl mx-auto">
          <%= for {phase, group} <- @phase_groups do %>
            <details
              class={["phase-section", phase == elem(hd(@phase_groups), 0) && "first-phase"]}
              open={phase >= @phase_number}
            >
              <summary class="flex items-center gap-3 my-6 cursor-pointer group list-none">
                <div class="flex-1 h-px bg-base-300" />
                <span class="flex items-center gap-1.5 text-xs font-medium text-base-content/40 uppercase tracking-wide group-hover:text-base-content/60 transition-colors">
                  Phase {phase} — {Workflows.phase_name(@workflow_session.workflow_type, phase)}
                  <.icon name="hero-chevron-down-micro" class="size-3 phase-chevron" />
                </span>
                <div class="flex-1 h-px bg-base-300" />
              </summary>
              <.chat_message
                :for={msg <- group}
                message={msg}
                workflow_session={@workflow_session}
                target={@myself}
              />
              <.chat_typing_indicator :if={
                phase == @phase_number && @workflow_session.phase_status == :generating
              } />
            </details>
          <% end %>

          <%!-- Inline structured options --%>
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
              target={@myself}
            />
          </div>

          <%!-- Inline multi-question form --%>
          <div
            :if={!@current_step.completed && @current_step.input_type == :questions}
            class="ml-11 mb-4"
          >
            <.multi_question_input
              questions={@current_step.questions}
              answers={@question_answers}
              target={@myself}
            />
          </div>
        </div>
      </div>

      <%!-- Text input --%>
      <div
        :if={
          !@current_step.completed &&
            @workflow_session.phase_status not in [:advance_suggested]
        }
        class="max-w-2xl mx-auto w-full px-6 pb-4"
      >
        <.text_input
          disabled={@workflow_session.phase_status == :generating}
          target={@myself}
        />
      </div>
    </div>
    """
  end

  # --- Private helpers ---

  defp refresh_from_db(socket) do
    ws = Workflows.get_workflow_session!(socket.assigns.workflow_session.id)
    ai_session = AI.get_ai_session_for_workflow(ws.id)
    messages = if ai_session, do: AI.list_messages(ai_session.id), else: []
    current_step = compute_current_step(ws, messages)

    {:noreply,
     socket
     |> assign(:workflow_session, ws)
     |> assign(:ai_session, ai_session)
     |> assign(:messages, messages)
     |> assign(:current_step, current_step)}
  end

  defp maybe_initialize_ai(socket, ws, _ai_session, phase_number, opts) do
    case Workflows.initialize_ai_conversation(ws.workflow_type, ws, phase_number, opts) do
      {:ok, ai_session} -> assign(socket, :ai_session, ai_session)
      :already_initialized -> socket
    end
  end

  defp compute_current_step(ws, messages) do
    cond do
      Destila.Workflows.Session.done?(ws) ->
        %{input_type: nil, options: nil, questions: [], completed: true}

      ws.phase_status == :advance_suggested ->
        %{input_type: nil, options: nil, questions: [], completed: false}

      ws.phase_status == :generating ->
        %{input_type: :text, options: nil, questions: [], completed: false}

      true ->
        last_system = messages |> Enum.filter(&(&1.role == :system)) |> List.last()

        if last_system do
          processed = AI.process_message(last_system, ws)

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

  defp phase_groups(messages, current_phase) do
    groups =
      messages
      |> Enum.group_by(& &1.phase)
      |> Enum.sort_by(fn {phase, _} -> phase end)

    if Enum.any?(groups, fn {phase, _} -> phase == current_phase end) do
      groups
    else
      groups ++ [{current_phase, []}]
    end
  end
end
