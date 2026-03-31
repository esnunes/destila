defmodule DestilaWeb.Phases.AiConversationPhase do
  @moduledoc """
  LiveComponent for AI conversation phases.

  Receives updates from the parent LiveView via `update/2` (driven by
  PubSub events the parent handles). Handles conversation-specific events
  (sending messages, retrying, cancelling). Workflow-level actions
  (confirm advance, decline advance, mark done) are handled by the
  parent `WorkflowRunnerLive`.

  Opts:
  - `name` — phase display name (required)
  - `system_prompt` — fn/1 returning the system prompt (required)
  - `skippable` — supports phase_complete session tool action (default false)
  - `final` — shows "Mark as Done" instead of advance (default false)
  - `non_interactive` — hides user input, shows retry/cancel (default false)
  - `allowed_tools` — list of tools for ClaudeCode session (optional)
  """

  use DestilaWeb, :live_component

  import DestilaWeb.ChatComponents

  alias Destila.AI
  alias Destila.Workflows

  def mount(socket) do
    {:ok, assign(socket, :question_answers, %{})}
  end

  def update(assigns, socket) do
    ws = assigns.workflow_session
    phase_number = assigns.phase_number
    opts = assigns.opts

    ai_session = AI.get_ai_session_for_workflow(ws.id)
    # Load messages from ALL AI sessions for this workflow (not just the latest)
    # so that earlier phase messages (e.g., planning phases 3-4) are visible
    # even when the current AI session is the implementation one (phases 5-8).
    messages = AI.list_messages_for_workflow_session(ws.id)
    current_step = compute_current_step(ws, messages)

    socket =
      socket
      |> assign(:workflow_session, ws)
      |> assign(:phase_number, phase_number)
      |> assign(:opts, opts)
      |> assign(:ai_session, ai_session)
      |> assign(:messages, messages)
      |> assign(:current_step, current_step)

    {:ok, socket}
  end

  # --- Chat events (targeted via phx-target={@myself}) ---

  def handle_event("send_text", %{"content" => content}, socket) when content != "" do
    ws = socket.assigns.workflow_session

    if ws.phase_status not in [:processing] do
      Destila.Executions.Engine.phase_update(ws.id, ws.current_phase, %{message: content})

      ws = Workflows.get_workflow_session!(ws.id)
      ai_session = AI.get_ai_session_for_workflow(ws.id)
      messages = if ai_session, do: AI.list_messages(ai_session.id), else: []

      {:noreply,
       socket
       |> assign(:workflow_session, ws)
       |> assign(:ai_session, ai_session)
       |> assign(:messages, messages)
       |> assign(:current_step, compute_current_step(ws, messages))}
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

  def handle_event("retry_phase", _params, socket) do
    ws = socket.assigns.workflow_session
    opts = socket.assigns.opts

    if Keyword.get(opts, :non_interactive, false) && ws.phase_status != :processing do
      # Stop existing session to avoid sending duplicate prompts
      AI.ClaudeSession.stop_for_workflow_session(ws.id)

      case Workflows.phase_start_action(ws) do
        :processing ->
          Workflows.update_workflow_session(ws, %{phase_status: :processing})
          {:noreply, assign(socket, :workflow_session, %{ws | phase_status: :processing})}

        :awaiting_input ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_phase", _params, socket) do
    ws = socket.assigns.workflow_session
    opts = socket.assigns.opts

    if Keyword.get(opts, :non_interactive, false) && ws.phase_status == :processing do
      AI.ClaudeSession.stop_for_workflow_session(ws.id)
      {:ok, ws} = Workflows.update_workflow_session(ws, %{phase_status: :conversing})
      {:noreply, assign(socket, :workflow_session, ws)}
    else
      {:noreply, socket}
    end
  end

  # --- Render ---

  def render(assigns) do
    metadata = assigns[:metadata] || %{}
    worktree_path = get_in(metadata, ["worktree", "worktree_path"])
    is_final = Keyword.get(assigns.opts, :final, false)
    non_interactive = Keyword.get(assigns.opts, :non_interactive, false)

    assigns =
      assigns
      |> assign(:phase_groups, phase_groups(assigns.messages, assigns.phase_number))
      |> assign(:non_interactive, non_interactive)
      |> assign(:worktree_path, worktree_path)
      |> assign(:show_worktree_banner, is_final && !non_interactive && worktree_path != nil)

    ~H"""
    <div class="flex flex-col h-full">
      <%!-- Scrollable chat area --%>
      <div class="flex-1 min-h-0 overflow-y-auto px-6 py-6" id="chat-messages" phx-hook="ScrollBottom">
        <div class="max-w-2xl mx-auto">
          <%!-- Worktree path banner for interactive final phase --%>
          <div
            :if={@show_worktree_banner}
            class="mb-6 rounded-lg border border-base-300 bg-base-200/50 p-4"
          >
            <div class="flex items-start gap-3">
              <.icon name="hero-folder-open" class="size-5 text-primary shrink-0 mt-0.5" />
              <div class="min-w-0">
                <p class="text-sm font-medium text-base-content/80">Source code</p>
                <code class="text-xs text-base-content/50 break-all">{@worktree_path}</code>
              </div>
            </div>
          </div>

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
                phase == @phase_number && @workflow_session.phase_status == :processing
              } />
            </details>
          <% end %>

          <%!-- Interactive-only: inline structured options --%>
          <div
            :if={
              !@non_interactive &&
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

          <%!-- Interactive-only: inline multi-question form --%>
          <div
            :if={
              !@non_interactive &&
                !@current_step.completed &&
                @current_step.input_type == :questions
            }
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

      <%!-- Non-interactive: retry/cancel controls --%>
      <div
        :if={@non_interactive && !@current_step.completed}
        class="max-w-2xl mx-auto w-full px-6 pb-4"
      >
        <div class="flex items-center justify-center gap-3">
          <button
            :if={@workflow_session.phase_status == :processing}
            phx-click="cancel_phase"
            phx-target={@myself}
            id="cancel-phase-btn"
            class="btn btn-outline btn-error btn-sm"
          >
            <.icon name="hero-stop-micro" class="size-4" /> Cancel
          </button>
          <button
            :if={@workflow_session.phase_status == :conversing}
            phx-click="retry_phase"
            phx-target={@myself}
            id="retry-phase-btn"
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-arrow-path-micro" class="size-4" /> Retry
          </button>
        </div>
      </div>

      <%!-- Interactive-only: text input --%>
      <div
        :if={
          !@non_interactive &&
            !@current_step.completed &&
            @workflow_session.phase_status not in [:advance_suggested]
        }
        class="max-w-2xl mx-auto w-full px-6 pb-4"
      >
        <.text_input
          disabled={@workflow_session.phase_status == :processing}
          target={@myself}
        />
      </div>
    </div>
    """
  end

  # --- Private helpers ---

  defp compute_current_step(ws, messages) do
    cond do
      Destila.Workflows.Session.done?(ws) ->
        %{input_type: nil, options: nil, questions: [], completed: true}

      ws.phase_status == :advance_suggested ->
        %{input_type: nil, options: nil, questions: [], completed: false}

      ws.phase_status == :processing ->
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
