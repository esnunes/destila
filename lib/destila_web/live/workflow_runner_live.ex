defmodule DestilaWeb.WorkflowRunnerLive do
  @moduledoc """
  Generic workflow runner LiveView. Orchestrates phase transitions and handles
  all chat events directly. Does not contain any workflow-specific logic.

  Single mount path:
  - `/sessions/:id` — running session with phase rendering

  Session creation is handled by `CreateSessionLive`.
  """

  use DestilaWeb, :live_view

  import DestilaWeb.BoardComponents,
    only: [workflow_badge: 1, progress_indicator: 1, aliveness_dot: 1]

  import DestilaWeb.ChatComponents

  alias Destila.AI
  alias Destila.AI.ResponseProcessor
  alias Destila.Sessions.SessionProcess
  alias Destila.Workflows
  alias Destila.Workflows.Session

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    mount_session(id, socket)
  end

  defp mount_session(id, socket) do
    workflow_session = Workflows.get_workflow_session(id)

    if workflow_session do
      alive_session =
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
          Phoenix.PubSub.subscribe(Destila.PubSub, Destila.PubSubHelper.ai_stream_topic(id))
          Phoenix.PubSub.subscribe(Destila.PubSub, Destila.AI.AlivenessTracker.topic())

          Destila.AI.AlivenessTracker.alive?(id)
        else
          false
        end

      workflow_type = workflow_session.workflow_type
      phases = Workflows.phases(workflow_type)

      project =
        if workflow_session.project_id,
          do: Destila.Projects.get_project(workflow_session.project_id)

      {:ok,
       socket
       |> assign(:view, :running)
       |> assign(:workflow_type, workflow_type)
       |> assign(:workflow_session, workflow_session)
       |> assign(:project, project)
       |> assign(:phases, phases)
       |> assign(:editing_title, false)
       |> assign_metadata(workflow_session.id)
       |> assign_worktree_path(workflow_session.id)
       |> assign(:ai_sessions, AI.list_ai_sessions_for_workflow(workflow_session.id))
       |> assign(:page_title, workflow_session.title)
       |> assign(:streaming_chunks, nil)
       |> assign(:intermediate_bubbles, [])
       |> assign(:alive_session, alive_session)
       |> assign(:question_answers, %{})
       |> assign(:editing_question_index, nil)
       |> assign(:editing_previous_answer, nil)
       |> assign(:video_modal_meta_id, nil)
       |> assign(:markdown_modal_content, nil)
       |> assign(:markdown_modal_label, nil)
       |> assign(:text_modal_content, nil)
       |> assign(:text_modal_label, nil)
       |> assign(:phase_status, Session.phase_status(workflow_session))
       |> assign_ai_state(workflow_session)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Session not found")
       |> assign(:alive_session, false)
       |> push_navigate(to: ~p"/crafting")}
    end
  end

  # --- Session management events ---

  @impl true
  def handle_event("edit_title", _params, socket) do
    {:noreply, assign(socket, :editing_title, true)}
  end

  def handle_event("save_title", %{"title" => title}, socket) do
    ws = socket.assigns.workflow_session
    title = String.trim(title)
    title = if title == "", do: ws.title, else: title
    {:ok, ws} = Workflows.update_workflow_session(ws, %{title: title})

    {:noreply,
     socket
     |> assign(:workflow_session, ws)
     |> assign(:editing_title, false)
     |> assign(:page_title, ws.title)}
  end

  def handle_event("archive_session", _params, socket) do
    {:ok, _ws} = Workflows.archive_workflow_session(socket.assigns.workflow_session)

    {:noreply,
     socket
     |> put_flash(:info, "Session archived")
     |> push_navigate(to: ~p"/crafting")}
  end

  def handle_event("unarchive_session", _params, socket) do
    {:ok, ws} = Workflows.unarchive_workflow_session(socket.assigns.workflow_session)

    {:noreply,
     socket
     |> assign(:workflow_session, ws)
     |> put_flash(:info, "Session restored")}
  end

  def handle_event("confirm_advance", _params, socket) do
    case SessionProcess.confirm_advance(socket.assigns.workflow_session.id) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> assign(:workflow_session, ws)
         |> assign(:page_title, ws.title)
         |> assign(:question_answers, %{})
         |> assign(:editing_question_index, nil)
         |> assign(:editing_previous_answer, nil)
         |> assign_ai_state(ws)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("decline_advance", _params, socket) do
    case SessionProcess.decline_advance(socket.assigns.workflow_session.id) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> assign(:workflow_session, ws)
         |> assign_ai_state(ws)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("mark_done", _params, socket) do
    case SessionProcess.mark_done(socket.assigns.workflow_session.id) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> assign(:workflow_session, ws)
         |> assign_ai_state(ws)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("mark_undone", _params, socket) do
    case SessionProcess.mark_undone(socket.assigns.workflow_session.id) do
      {:ok, ws} ->
        {:noreply, assign(socket, :workflow_session, ws)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("retry_setup", _params, socket) do
    case SessionProcess.retry_setup(socket.assigns.workflow_session.id) do
      {:ok, ws} ->
        {:noreply, assign(socket, :workflow_session, ws)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  # --- Chat events (previously in AiConversationPhase) ---

  def handle_event("send_text", %{"content" => content}, socket) when content != "" do
    case SessionProcess.send_message(socket.assigns.workflow_session.id, content) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> assign(:workflow_session, ws)
         |> assign_ai_state(ws)}

      {:error, _} ->
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

        {:noreply,
         socket
         |> assign(:question_answers, answers)
         |> assign(:editing_question_index, nil)
         |> assign(:editing_previous_answer, nil)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("answer_question", _params, socket), do: {:noreply, socket}

  def handle_event("reopen_question", %{"index" => idx_str}, socket) do
    case Integer.parse(idx_str) do
      {idx, _} ->
        previous_answer = socket.assigns.question_answers[idx]
        answers = Map.delete(socket.assigns.question_answers, idx)

        {:noreply,
         socket
         |> assign(:question_answers, answers)
         |> assign(:editing_question_index, idx)
         |> assign(:editing_previous_answer, previous_answer)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("reopen_question", _params, socket), do: {:noreply, socket}

  def handle_event("confirm_multi_answer", params, socket) do
    case Integer.parse(params["index"] || "") do
      {idx, _} ->
        selected = Map.get(params, "selected", [])
        other = Map.get(params, "other", "")
        all_selected = if other != "", do: selected ++ [other], else: selected

        if all_selected != [] do
          value = Enum.join(all_selected, ", ")
          answers = Map.put(socket.assigns.question_answers, idx, value)

          {:noreply,
           socket
           |> assign(:question_answers, answers)
           |> assign(:editing_question_index, nil)
           |> assign(:editing_previous_answer, nil)}
        else
          {:noreply, socket}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("submit_all_answers", _params, socket) do
    ws = socket.assigns.workflow_session
    messages = socket.assigns.messages
    last_system = messages |> Enum.filter(&(&1.role == :system)) |> List.last()

    if last_system do
      processed = ResponseProcessor.process_message(last_system, ws)
      answers = socket.assigns.question_answers

      response_parts =
        processed.questions
        |> Enum.with_index()
        |> Enum.map(fn {q, idx} ->
          value = answers[idx] || ""
          "**#{q.title}**: #{value}"
        end)

      content = Enum.join(response_parts, "\n")

      socket =
        socket
        |> assign(:question_answers, %{})
        |> assign(:editing_question_index, nil)
        |> assign(:editing_previous_answer, nil)

      handle_event("send_text", %{"content" => content}, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("retry_phase", _params, socket) do
    case SessionProcess.retry(socket.assigns.workflow_session.id) do
      {:ok, ws} ->
        {:noreply, assign(socket, :workflow_session, ws)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_phase", _params, socket) do
    case SessionProcess.cancel(socket.assigns.workflow_session.id) do
      {:ok, ws} ->
        {:noreply, assign(socket, :workflow_session, ws)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("open_video_modal", %{"id" => id}, socket) do
    {:noreply, assign(socket, :video_modal_meta_id, id)}
  end

  def handle_event("close_video_modal", _params, socket) do
    {:noreply, assign(socket, :video_modal_meta_id, nil)}
  end

  def handle_event("open_markdown_modal", %{"id" => id}, socket) do
    meta = Enum.find(socket.assigns.exported_metadata, &(&1.id == id))

    {:noreply,
     socket
     |> assign(:markdown_modal_content, meta.value["markdown"])
     |> assign(:markdown_modal_label, humanize_key(meta.key))}
  end

  def handle_event("open_markdown_modal", %{"content" => content, "label" => label}, socket) do
    {:noreply,
     socket
     |> assign(:markdown_modal_content, content)
     |> assign(:markdown_modal_label, label)}
  end

  def handle_event("close_markdown_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:markdown_modal_content, nil)
     |> assign(:markdown_modal_label, nil)}
  end

  def handle_event("open_text_modal", %{"id" => id}, socket) do
    meta = Enum.find(socket.assigns.exported_metadata, &(&1.id == id))

    case meta.value do
      %{"text_file" => path} ->
        case File.read(path) do
          {:ok, content} ->
            if Path.extname(path) == ".md" do
              {:noreply,
               socket
               |> assign(:markdown_modal_content, content)
               |> assign(:markdown_modal_label, humanize_key(meta.key))}
            else
              {:noreply,
               socket
               |> assign(:text_modal_content, content)
               |> assign(:text_modal_label, humanize_key(meta.key))}
            end

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not read file: #{path}")}
        end

      %{"text" => content} ->
        {:noreply,
         socket
         |> assign(:text_modal_content, content)
         |> assign(:text_modal_label, humanize_key(meta.key))}
    end
  end

  def handle_event("close_text_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:text_modal_content, nil)
     |> assign(:text_modal_label, nil)}
  end

  # PubSub: workflow session updated — refresh shared chrome
  @impl true
  def handle_info({:workflow_session_updated, updated_ws}, socket) do
    if socket.assigns[:workflow_session] &&
         updated_ws.id == socket.assigns.workflow_session.id do
      ws = Workflows.get_workflow_session!(updated_ws.id)
      phase_status = Session.phase_status(ws)

      {:noreply,
       socket
       |> assign(:workflow_session, ws)
       |> assign(:page_title, ws.title)
       |> assign(:phase_status, phase_status)
       |> assign(
         :streaming_chunks,
         if(phase_status == :processing,
           do: socket.assigns[:streaming_chunks],
           else: nil
         )
       )
       |> assign(
         :intermediate_bubbles,
         if(phase_status == :processing,
           do: socket.assigns.intermediate_bubbles,
           else: []
         )
       )
       |> assign_metadata(ws.id)
       |> assign_worktree_path(ws.id)
       |> assign_ai_state(ws)}
    else
      {:noreply, socket}
    end
  end

  # PubSub: metadata changed — refresh metadata assign for active phase component
  def handle_info({:metadata_updated, ws_id}, socket) do
    if socket.assigns[:workflow_session] && ws_id == socket.assigns.workflow_session.id do
      {:noreply,
       socket
       |> assign_metadata(ws_id)
       |> assign_ai_state(socket.assigns.workflow_session)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:ai_stream_chunk, chunk}, socket) do
    chunks = socket.assigns[:streaming_chunks] || []
    bubbles = socket.assigns.intermediate_bubbles

    bubbles =
      case extract_intermediate_text(chunk) do
        {:ok, text} ->
          bubbles ++ [%{text: text}]

        :skip ->
          bubbles
      end

    {:noreply,
     socket
     |> assign(:streaming_chunks, chunks ++ [chunk])
     |> assign(:intermediate_bubbles, bubbles)}
  end

  def handle_info({:aliveness_changed, ws_id, alive?}, socket) do
    if socket.assigns[:workflow_session] && ws_id == socket.assigns.workflow_session.id do
      {:noreply, assign(socket, :alive_session, alive?)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:ai_session_created, ai_session}, socket) do
    if socket.assigns[:workflow_session] &&
         ai_session.workflow_session_id == socket.assigns.workflow_session.id do
      ws_id = socket.assigns.workflow_session.id
      {:noreply, assign(socket, :ai_sessions, AI.list_ai_sessions_for_workflow(ws_id))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:message_added, message}, socket) do
    if socket.assigns[:workflow_session] &&
         message.workflow_session_id == socket.assigns.workflow_session.id do
      ws_id = socket.assigns.workflow_session.id
      {:noreply, assign(socket, :ai_sessions, AI.list_ai_sessions_for_workflow(ws_id))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp extract_intermediate_text(%ClaudeCode.Message.AssistantMessage{message: message}) do
    text =
      message.content
      |> Enum.filter(&match?(%ClaudeCode.Content.TextBlock{}, &1))
      |> Enum.map_join(& &1.text)

    if String.trim(text) != "", do: {:ok, text}, else: :skip
  end

  defp extract_intermediate_text(%ClaudeCode.Message.ResultMessage{result: result})
       when is_binary(result) do
    if String.trim(result) != "", do: {:ok, result}, else: :skip
  end

  defp extract_intermediate_text(_chunk), do: :skip

  # --- Private: AI state management ---

  defp assign_ai_state(socket, ws) do
    messages = AI.list_messages_for_workflow_session(ws.id)
    current_step = compute_current_step(ws, socket.assigns.phase_status, messages)

    socket
    |> assign(:messages, messages)
    |> assign(:current_step, current_step)
  end

  defp compute_current_step(ws, phase_status, messages) do
    cond do
      phase_status == :setup ->
        %{input_type: nil, options: nil, questions: [], question_title: nil, completed: false}

      Session.done?(ws) ->
        %{input_type: nil, options: nil, questions: [], question_title: nil, completed: true}

      phase_status == :awaiting_confirmation ->
        %{input_type: nil, options: nil, questions: [], question_title: nil, completed: false}

      phase_status == :processing ->
        %{input_type: :text, options: nil, questions: [], question_title: nil, completed: false}

      true ->
        last_system = messages |> Enum.filter(&(&1.role == :system)) |> List.last()

        if last_system do
          processed = ResponseProcessor.process_message(last_system, ws)

          question_title =
            case processed.questions do
              [q] -> q.question
              _ -> nil
            end

          %{
            input_type: processed.input_type,
            options: processed.options,
            questions: processed.questions,
            question_title: question_title,
            completed: false
          }
        else
          %{input_type: :text, options: nil, questions: [], question_title: nil, completed: false}
        end
    end
  end

  # --- Render: running workflow ---

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title}>
      <div class="flex flex-col h-screen">
        <%!-- Header --%>
        <div class="border-b border-base-300 bg-base-100 px-6 py-4">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-4 flex-1 min-w-0">
              <.link navigate={~p"/crafting"} class="btn btn-ghost btn-sm btn-square">
                <.icon name="hero-arrow-left-micro" class="size-4" />
              </.link>

              <div class="flex-1 min-w-0">
                <%= if @workflow_session do %>
                  <div :if={!@editing_title} class="flex items-center gap-2">
                    <.aliveness_dot session={@workflow_session} alive?={@alive_session} />
                    <h1
                      class={[
                        "text-lg font-bold truncate transition-colors",
                        if(@workflow_session.title_generating,
                          do: "animate-pulse text-base-content/50",
                          else: "cursor-pointer hover:text-primary"
                        )
                      ]}
                      phx-click={if(!@workflow_session.title_generating, do: "edit_title")}
                    >
                      {@workflow_session.title}
                    </h1>
                    <button
                      :if={!@workflow_session.title_generating}
                      phx-click="edit_title"
                      class="cursor-pointer"
                    >
                      <.icon name="hero-pencil-micro" class="size-3.5 text-base-content/30" />
                    </button>
                  </div>

                  <form
                    :if={@editing_title}
                    phx-submit="save_title"
                    class="flex items-center gap-2"
                  >
                    <input
                      type="text"
                      name="title"
                      value={@workflow_session.title}
                      class="input input-bordered input-sm w-full max-w-md"
                      autofocus
                      phx-blur="save_title"
                      phx-value-title={@workflow_session.title}
                    />
                  </form>
                <% else %>
                  <h1 class="text-lg font-bold truncate">
                    {Workflows.default_title(@workflow_type)}
                  </h1>
                <% end %>

                <div class="flex items-center gap-3 mt-1">
                  <.workflow_badge type={@workflow_type} />
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
              <div :if={@workflow_session.total_phases > 1} class="flex items-center gap-2">
                <div class="w-24">
                  <.progress_indicator
                    completed={@workflow_session.current_phase}
                    total={@workflow_session.total_phases}
                  />
                </div>
                <span class="text-xs text-base-content/40">
                  Phase {@workflow_session.current_phase}/{@workflow_session.total_phases}
                  <span
                    :if={Workflows.phase_name(@workflow_type, @workflow_session.current_phase)}
                    class="hidden sm:inline"
                  >
                    — {Workflows.phase_name(@workflow_type, @workflow_session.current_phase)}
                  </span>
                </span>
              </div>

              <%!-- Mark as Done / Reopen --%>
              <button
                :if={
                  @workflow_session &&
                    @workflow_session.current_phase == @workflow_session.total_phases &&
                    !Session.done?(@workflow_session)
                }
                phx-click="mark_done"
                id="mark-done-btn"
                disabled={@phase_status == :processing}
                class="btn btn-success btn-sm"
              >
                <.icon name="hero-check-micro" class="size-4" /> Mark as Done
              </button>
              <button
                :if={@workflow_session && Session.done?(@workflow_session)}
                phx-click="mark_undone"
                id="reopen-btn"
                class="btn btn-soft btn-sm"
              >
                <.icon name="hero-arrow-path-micro" class="size-4" /> Reopen
              </button>

              <%!-- Archive / Unarchive --%>
              <%= if @workflow_session do %>
                <button
                  :if={is_nil(@workflow_session.archived_at)}
                  phx-click="archive_session"
                  id="archive-btn"
                  class="btn btn-soft btn-sm"
                  data-confirm="Archive this session? It will be hidden from the crafting board."
                >
                  <.icon name="hero-archive-box-micro" class="size-4" /> Archive
                </button>
                <button
                  :if={@workflow_session.archived_at}
                  phx-click="unarchive_session"
                  id="unarchive-btn"
                  class="btn btn-soft btn-sm"
                >
                  <.icon name="hero-archive-box-arrow-down-micro" class="size-4" /> Unarchive
                </button>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Phase content + sidebar — full remaining height --%>
        <div class="flex flex-row flex-1 min-h-0">
          <%!-- Phase content — takes remaining space --%>
          <div class="flex-1 min-w-0 min-h-0 overflow-hidden">
            {render_phase(assigns)}
          </div>

          <%!-- Exported metadata sidebar --%>
          <%= if @workflow_session do %>
            <div
              id="metadata-sidebar"
              phx-hook=".MetadataSidebar"
              class="flex flex-col border-l border-base-300 shrink-0 bg-base-100"
            >
              <%!-- Toggle button — always visible --%>
              <button
                id="metadata-sidebar-toggle"
                class="px-3 py-2.5 border-b border-base-300 bg-base-100 hover:bg-base-200/60 transition-colors duration-150 flex items-center gap-1.5"
                data-action="toggle-sidebar"
              >
                <.icon
                  name="hero-chevron-right-micro"
                  class="size-3.5 text-base-content/40 sidebar-icon-collapsed hidden"
                />
                <.icon
                  name="hero-chevron-left-micro"
                  class="size-3.5 text-base-content/40 sidebar-icon-expanded"
                />
                <span class="text-[10px] font-semibold text-base-content/40 uppercase tracking-wider sidebar-label-expanded">
                  Output
                </span>
              </button>

              <%!-- Sidebar content — toggled by hook --%>
              <div id="metadata-sidebar-content" class="w-80 overflow-y-auto flex-1">
                <%!-- Input section — user prompt + source code --%>
                <div id="user-prompt-section" class="px-3 pt-3 pb-3">
                  <h3 class="text-[10px] font-semibold text-base-content/40 uppercase tracking-wider mb-1.5 px-2">
                    Workflow Session
                  </h3>
                  <div class="space-y-0.5">
                    <button
                      id="view-user-prompt-btn"
                      phx-click="open_markdown_modal"
                      phx-value-content={@workflow_session.user_prompt}
                      phx-value-label="User Prompt"
                      class="w-full flex items-center gap-2.5 px-2 py-1.5 rounded-md hover:bg-base-200/60 transition-colors duration-150 group"
                      aria-label="View user prompt"
                    >
                      <span class="size-5 rounded flex items-center justify-center shrink-0">
                        <.icon
                          name="hero-chat-bubble-left-ellipsis-micro"
                          class="size-3.5 text-base-content/30"
                        />
                      </span>
                      <span class="text-sm text-base-content/60 truncate flex-1 text-left">
                        User Prompt
                      </span>
                      <.icon
                        name="hero-eye-micro"
                        class="size-3.5 text-base-content/30 group-hover:text-primary transition-colors"
                      />
                    </button>
                    <.link
                      :if={@worktree_path}
                      id="open-terminal-btn"
                      navigate={~p"/sessions/#{@workflow_session.id}/terminal"}
                      class="w-full flex items-center gap-2.5 px-2 py-1.5 rounded-md hover:bg-base-200/60 transition-colors duration-150 group"
                      aria-label="Open terminal"
                    >
                      <span class="size-5 rounded flex items-center justify-center shrink-0">
                        <.icon
                          name="hero-command-line-micro"
                          class="size-3.5 text-base-content/30"
                        />
                      </span>
                      <span class="text-sm text-base-content/60 truncate flex-1">
                        Terminal
                      </span>
                      <.icon
                        name="hero-arrow-top-right-on-square-micro"
                        class="size-3.5 text-base-content/30 group-hover:text-primary transition-colors"
                      />
                    </.link>
                    <%= if @project do %>
                      <% service_running? = @workflow_session.service_state["status"] == "running" %>
                      <% url = service_url(@project, @workflow_session.service_state) %>
                      <%= if @project.run_command do %>
                        <%= if url do %>
                          <a
                            id="service-status-link"
                            href={url}
                            target="_blank"
                            class="w-full flex items-center gap-2.5 px-2 py-1.5 rounded-md hover:bg-base-200/60 transition-colors duration-150 group"
                            aria-label="Open service"
                          >
                            <span class="size-5 rounded flex items-center justify-center shrink-0 relative">
                              <.icon
                                name="hero-server-micro"
                                class="size-3.5 text-green-500 transition-colors duration-300"
                              />
                              <span class="absolute -top-0.5 -right-0.5 size-2 rounded-full bg-green-500 ring-2 ring-base-100 animate-pulse">
                              </span>
                            </span>
                            <span class="text-sm text-base-content/80 truncate flex-1 text-left">
                              Service
                            </span>
                            <.icon
                              name="hero-arrow-top-right-on-square-micro"
                              class="size-3.5 text-base-content/30 group-hover:text-primary transition-colors"
                            />
                          </a>
                        <% else %>
                          <div
                            id="service-status-item"
                            class="w-full flex items-center gap-2.5 px-2 py-1.5 rounded-md hover:bg-base-200/60 transition-colors duration-150"
                            aria-label="Service status"
                          >
                            <span class="size-5 rounded flex items-center justify-center shrink-0 relative">
                              <.icon
                                name="hero-server-micro"
                                class={[
                                  "size-3.5 transition-colors duration-300",
                                  if(service_running?,
                                    do: "text-green-500",
                                    else: "text-base-content/30"
                                  )
                                ]}
                              />
                              <span
                                :if={service_running?}
                                class="absolute -top-0.5 -right-0.5 size-2 rounded-full bg-green-500 ring-2 ring-base-100 animate-pulse"
                              >
                              </span>
                            </span>
                            <span class={[
                              "text-sm truncate flex-1 text-left transition-colors duration-300",
                              if(service_running?,
                                do: "text-base-content/80",
                                else: "text-base-content/60"
                              )
                            ]}>
                              Service
                            </span>
                            <span
                              :if={service_running?}
                              class="text-[10px] font-medium text-green-600 dark:text-green-400 uppercase tracking-wide"
                            >
                              Live
                            </span>
                          </div>
                        <% end %>
                      <% else %>
                        <div
                          id="service-status-item"
                          class="w-full flex items-center gap-2.5 px-2 py-1.5 rounded-md cursor-default"
                          aria-label="Service not configured"
                          title="No run command configured"
                        >
                          <span class="size-5 rounded flex items-center justify-center shrink-0">
                            <.icon
                              name="hero-server-micro"
                              class="size-3.5 text-base-content/15"
                            />
                          </span>
                          <span class="text-sm text-base-content/30 truncate flex-1 text-left">
                            Service
                          </span>
                        </div>
                      <% end %>
                    <% end %>
                  </div>
                </div>

                <%!-- Divider between input and output --%>
                <div class="border-t border-base-300/60 mx-3"></div>

                <%!-- Exported metadata section — primary content --%>
                <div class="px-3 pt-3 pb-3 flex-1">
                  <h3 class="text-[10px] font-semibold text-base-content/40 uppercase tracking-wider mb-1.5 px-2">
                    Exported Metadata
                  </h3>

                  <%= if @exported_metadata == [] do %>
                    <div class="flex flex-col items-center py-10 text-center">
                      <.icon
                        name="hero-inbox-micro"
                        class="size-7 text-base-content/10 mb-2.5"
                      />
                      <p class="text-xs text-base-content/25">
                        No metadata exported yet
                      </p>
                    </div>
                  <% else %>
                    <div class="space-y-0.5">
                      <%= for meta <- @exported_metadata do %>
                        <%= cond do %>
                          <% Map.has_key?(meta.value, "video_file") -> %>
                            <button
                              id={"metadata-entry-#{meta.id}"}
                              phx-click="open_video_modal"
                              phx-value-id={meta.id}
                              class="w-full flex items-center gap-2.5 px-2 py-1.5 rounded-md hover:bg-base-200/60 transition-colors duration-150 group"
                              aria-label={"Play #{humanize_key(meta.key)}"}
                            >
                              <span class="size-5 rounded flex items-center justify-center bg-error/10 shrink-0">
                                <.icon
                                  name="hero-film-micro"
                                  class="size-3 text-error/70"
                                />
                              </span>
                              <span class="text-sm text-base-content/60 truncate flex-1 text-left">
                                {humanize_key(meta.key)}
                              </span>
                              <.icon
                                name="hero-play-micro"
                                class="size-3.5 text-base-content/30 group-hover:text-primary transition-colors"
                              />
                            </button>
                          <% Map.has_key?(meta.value, "markdown") -> %>
                            <button
                              id={"metadata-entry-#{meta.id}"}
                              phx-click="open_markdown_modal"
                              phx-value-id={meta.id}
                              class="w-full flex items-center gap-2.5 px-2 py-1.5 rounded-md hover:bg-base-200/60 transition-colors duration-150 group"
                              aria-label={"View #{humanize_key(meta.key)}"}
                            >
                              <span class="size-5 rounded flex items-center justify-center bg-info/10 shrink-0">
                                <.icon
                                  name="hero-document-text-micro"
                                  class="size-3 text-info/70"
                                />
                              </span>
                              <span class="text-sm text-base-content/60 truncate flex-1 text-left">
                                {humanize_key(meta.key)}
                              </span>
                              <.icon
                                name="hero-eye-micro"
                                class="size-3.5 text-base-content/30 group-hover:text-primary transition-colors"
                              />
                            </button>
                          <% Map.has_key?(meta.value, "text_file") or Map.has_key?(meta.value, "text") -> %>
                            <button
                              id={"metadata-entry-#{meta.id}"}
                              phx-click="open_text_modal"
                              phx-value-id={meta.id}
                              class="w-full flex items-center gap-2.5 px-2 py-1.5 rounded-md hover:bg-base-200/60 transition-colors duration-150 group"
                              aria-label={"View #{humanize_key(meta.key)}"}
                            >
                              <span class="size-5 rounded flex items-center justify-center bg-success/10 shrink-0">
                                <.icon
                                  name="hero-document-text-micro"
                                  class="size-3 text-success/70"
                                />
                              </span>
                              <span class="text-sm text-base-content/60 truncate flex-1 text-left">
                                {humanize_key(meta.key)}
                              </span>
                              <.icon
                                name="hero-eye-micro"
                                class="size-3.5 text-base-content/30 group-hover:text-primary transition-colors"
                              />
                            </button>
                          <% true -> %>
                            <details
                              id={"metadata-entry-#{meta.id}"}
                              class="group rounded-md overflow-hidden"
                              open
                            >
                              <summary class="flex items-center gap-2.5 cursor-pointer px-2 py-1.5 rounded-md hover:bg-base-200/60 transition-colors duration-150 text-sm select-none">
                                <span class="size-5 rounded flex items-center justify-center bg-warning/10 shrink-0">
                                  <.icon
                                    name="hero-chevron-right-micro"
                                    class="size-3 text-warning/70 group-open:rotate-90 transition-transform duration-150"
                                  />
                                </span>
                                <span class="text-base-content/60 truncate">
                                  {humanize_key(meta.key)}
                                </span>
                              </summary>
                              <div class="ml-[18px] mt-0.5 border-l-2 border-base-300/60 bg-base-200/20 rounded-r-md">
                                <.metadata_value_block value={meta.value} />
                              </div>
                            </details>
                        <% end %>
                      <% end %>
                    </div>
                  <% end %>
                </div>

                <%!-- Divider between exported metadata and AI sessions --%>
                <div class="border-t border-base-300/60 mx-3"></div>

                <%!-- AI Sessions section --%>
                <div id="ai-sessions-section" class="px-3 pt-3 pb-6">
                  <h3 class="text-[10px] font-semibold text-base-content/40 uppercase tracking-wider mb-1.5 px-2">
                    AI Sessions
                  </h3>
                  <%= if @ai_sessions == [] do %>
                    <div
                      id="ai-sessions-empty-state"
                      class="flex flex-col items-center py-6 text-center"
                    >
                      <p class="text-xs text-base-content/25">No AI sessions yet</p>
                    </div>
                  <% else %>
                    <div class="space-y-0.5">
                      <%= for session <- @ai_sessions do %>
                        <.link
                          id={"ai-session-item-#{session.id}"}
                          navigate={~p"/sessions/#{@workflow_session.id}/ai/#{session.id}"}
                          class="w-full flex items-center gap-2.5 px-2 py-1.5 rounded-md hover:bg-base-200/60 transition-colors duration-150 group"
                        >
                          <span class="size-5 rounded flex items-center justify-center shrink-0">
                            <.icon
                              name="hero-cpu-chip-micro"
                              class="size-3.5 text-base-content/30"
                            />
                          </span>
                          <span class="text-sm text-base-content/60 truncate flex-1">
                            AI Session
                          </span>
                          <span class="text-xs text-base-content/40 tabular-nums">
                            {session.message_count}
                          </span>
                          <.icon
                            name="hero-arrow-top-right-on-square-micro"
                            class="size-3.5 text-base-content/30 group-hover:text-primary transition-colors"
                          />
                        </.link>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <%!-- Workflow complete banner --%>
        <div
          :if={@workflow_session && Session.done?(@workflow_session)}
          class="border-t border-base-300 bg-base-200/50 px-4 py-3"
        >
          <p class="text-sm text-base-content/50 flex items-center justify-center gap-2">
            <.icon name="hero-check-circle-solid" class="size-4 text-success" />
            <span>Workflow complete</span>
          </p>
        </div>
      </div>

      <%!-- Video modal --%>
      <div
        :if={@video_modal_meta_id}
        id="video-modal"
        class="fixed inset-0 z-50 flex items-center justify-center"
      >
        <div
          class="absolute inset-0 bg-black/70 backdrop-blur-sm"
          phx-click="close_video_modal"
        />
        <div class="relative z-10 w-full max-w-3xl mx-4">
          <button
            phx-click="close_video_modal"
            class="absolute -top-10 right-0 text-white/70 hover:text-white transition-colors"
            aria-label="Close video"
          >
            <.icon name="hero-x-mark" class="size-6" />
          </button>
          <video controls autoplay class="w-full rounded-xl shadow-2xl">
            <source src={"/media/#{@video_modal_meta_id}"} type="video/mp4" />
          </video>
        </div>
      </div>

      <%!-- Markdown modal --%>
      <%= if @markdown_modal_content do %>
        <div
          id="markdown-modal"
          class="fixed inset-0 z-50 flex items-center justify-center"
        >
          <div
            class="absolute inset-0 bg-black/70 backdrop-blur-sm"
            phx-click="close_markdown_modal"
          />
          <div class="relative z-10 w-full max-w-3xl mx-4">
            <button
              phx-click="close_markdown_modal"
              class="absolute -top-10 right-0 text-white/70 hover:text-white transition-colors"
              aria-label="Close markdown"
            >
              <.icon name="hero-x-mark" class="size-6" />
            </button>
            <div class="rounded-xl bg-base-200 shadow-2xl overflow-hidden max-h-[80vh] overflow-y-auto">
              <.markdown_viewer
                id="markdown-modal-viewer"
                content={@markdown_modal_content}
                label={@markdown_modal_label}
              />
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Text modal --%>
      <%= if @text_modal_content do %>
        <div
          id="text-modal"
          class="fixed inset-0 z-50 flex items-center justify-center"
        >
          <div
            class="absolute inset-0 bg-black/70 backdrop-blur-sm"
            phx-click="close_text_modal"
          />
          <div class="relative z-10 w-full max-w-3xl mx-4">
            <button
              phx-click="close_text_modal"
              class="absolute -top-10 right-0 text-white/70 hover:text-white transition-colors"
              aria-label="Close text"
            >
              <.icon name="hero-x-mark" class="size-6" />
            </button>
            <div class="rounded-xl bg-base-200 shadow-2xl overflow-hidden max-h-[80vh] flex flex-col">
              <div class="px-4 py-3 bg-base-300/50 border-b border-base-300 flex items-center justify-between">
                <span class="text-sm font-medium text-base-content/70">
                  {@text_modal_label}
                </span>
              </div>
              <div class="overflow-y-auto p-4">
                <pre class="text-sm text-base-content/80 whitespace-pre-wrap break-words leading-relaxed">{@text_modal_content}</pre>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".MetadataSidebar">
        export default {
          mounted() {
            const collapsed = localStorage.getItem("metadata-sidebar-collapsed") === "true"
            this.applyState(collapsed)

            this.el.querySelector("[data-action=toggle-sidebar]")
              .addEventListener("click", () => {
                const isCollapsed = this.el.dataset.collapsed === "true"
                this.applyState(!isCollapsed)
                localStorage.setItem("metadata-sidebar-collapsed", String(!isCollapsed))
              })
          },
          updated() {
            const collapsed = localStorage.getItem("metadata-sidebar-collapsed") === "true"
            this.applyState(collapsed)
          },
          applyState(collapsed) {
            const content = this.el.querySelector("#metadata-sidebar-content")
            const iconCollapsed = this.el.querySelector(".sidebar-icon-collapsed")
            const iconExpanded = this.el.querySelector(".sidebar-icon-expanded")
            const labelExpanded = this.el.querySelector(".sidebar-label-expanded")

            if (!content || !iconCollapsed || !iconExpanded) return

            this.el.dataset.collapsed = collapsed

            if (collapsed) {
              content.classList.add("hidden")
              iconCollapsed.classList.remove("hidden")
              iconExpanded.classList.add("hidden")
              if (labelExpanded) labelExpanded.classList.add("hidden")
            } else {
              content.classList.remove("hidden")
              iconCollapsed.classList.add("hidden")
              iconExpanded.classList.remove("hidden")
              if (labelExpanded) labelExpanded.classList.remove("hidden")
            }
          }
        }
      </script>
    </Layouts.app>
    """
  end

  # --- Generic phase rendering ---

  defp render_phase(assigns) do
    do_render_phase(assigns)
  end

  defp do_render_phase(%{phases: phases, workflow_session: ws} = assigns) do
    case Enum.at(phases, ws.current_phase - 1) do
      %Destila.Workflows.Phase{} = phase ->
        assigns = assign(assigns, :phase_config, phase)

        ~H"""
        <.chat_phase
          workflow_session={@workflow_session}
          messages={@messages}
          phase_number={@workflow_session.current_phase}
          phase_config={@phase_config}
          streaming_chunks={@streaming_chunks}
          intermediate_bubbles={@intermediate_bubbles}
          question_answers={@question_answers}
          editing_question_index={@editing_question_index}
          editing_previous_answer={@editing_previous_answer}
          metadata={@metadata}
          current_step={@current_step}
          phase_status={@phase_status}
          exported_metadata={@exported_metadata}
        />
        """

      nil ->
        ~H"""
        <div class="text-base-content/50 text-center py-12">
          Phase {@workflow_session.current_phase}
        </div>
        """
    end
  end

  defp assign_metadata(socket, ws_id) do
    all = Workflows.get_all_metadata(ws_id)

    socket
    |> assign(:metadata, Enum.reduce(all, %{}, fn m, acc -> Map.put(acc, m.key, m.value) end))
    |> assign(:exported_metadata, Enum.filter(all, & &1.exported))
  end

  defp service_url(%{port_definitions: [first_port | _]}, %{
         "status" => "running",
         "ports" => ports
       })
       when is_map(ports) do
    case Map.get(ports, first_port) do
      nil -> nil
      port -> "http://localhost:#{port}"
    end
  end

  defp service_url(_project, _service_state), do: nil

  defp assign_worktree_path(socket, ws_id) do
    ai_session = AI.get_ai_session_for_workflow(ws_id)

    socket
    |> assign(:worktree_path, ai_session && ai_session.worktree_path)
    |> assign(:claude_session_id, ai_session && ai_session.claude_session_id)
  end

  defp metadata_value_block(assigns) do
    escaped =
      assigns.value
      |> format_metadata_value()
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()

    assigns =
      assign(
        assigns,
        :content,
        Phoenix.HTML.raw(
          ~s(<div class="text-xs text-base-content/60 p-3 max-h-96 overflow-y-auto whitespace-pre-wrap break-words leading-relaxed">) <>
            escaped <> "</div>"
        )
      )

    ~H"{@content}"
  end

  defp format_metadata_value(%{"text" => text}) when is_binary(text), do: text
  defp format_metadata_value(%{"markdown" => md}) when is_binary(md), do: md
  defp format_metadata_value(%{"text_file" => path}) when is_binary(path), do: path
  defp format_metadata_value(%{"video_file" => path}) when is_binary(path), do: path
  defp format_metadata_value(value) when is_map(value), do: Jason.encode!(value, pretty: true)
  defp format_metadata_value(value), do: inspect(value)

  defp humanize_key(key) when is_binary(key) do
    key
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
