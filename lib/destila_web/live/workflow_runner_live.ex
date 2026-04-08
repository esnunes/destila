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

  def mount(%{"id" => id}, session, socket) do
    socket = assign(socket, :current_user, session["current_user"])
    mount_session(id, socket)
  end

  defp mount_session(id, socket) do
    workflow_session = Workflows.get_workflow_session(id)

    if workflow_session do
      {alive_session, alive_session_ref} =
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
          Phoenix.PubSub.subscribe(Destila.PubSub, Destila.PubSubHelper.ai_stream_topic(id))
          Phoenix.PubSub.subscribe(Destila.PubSub, Destila.PubSubHelper.claude_session_topic())

          case GenServer.whereis({:via, Registry, {Destila.AI.SessionRegistry, id}}) do
            nil -> {false, nil}
            pid -> {true, Process.monitor(pid)}
          end
        else
          {false, nil}
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
       |> assign(:page_title, workflow_session.title)
       |> assign(:streaming_chunks, nil)
       |> assign(:alive_session, alive_session)
       |> assign(:alive_session_ref, alive_session_ref)
       |> assign(:question_answers, %{})
       |> assign(:phase_status, Session.phase_status(workflow_session))
       |> assign_ai_state(workflow_session)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Session not found")
       |> assign(:alive_session, false)
       |> assign(:alive_session_ref, nil)
       |> push_navigate(to: ~p"/crafting")}
    end
  end

  # --- Session management events ---

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
      socket = assign(socket, :question_answers, %{})
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

  # PubSub: workflow session updated — refresh shared chrome
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
    {:noreply, assign(socket, :streaming_chunks, chunks ++ [chunk])}
  end

  def handle_info({:claude_session_started, ws_id}, socket) do
    if socket.assigns[:workflow_session] && ws_id == socket.assigns.workflow_session.id do
      name = {:via, Registry, {Destila.AI.SessionRegistry, ws_id}}

      case GenServer.whereis(name) do
        nil ->
          {:noreply, socket}

        pid ->
          ref = Process.monitor(pid)
          {:noreply, assign(socket, alive_session: true, alive_session_ref: ref)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
    if ref == socket.assigns[:alive_session_ref] do
      {:noreply, assign(socket, alive_session: false, alive_session_ref: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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
              <div class="flex items-center gap-2">
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
                    !Session.done?(@workflow_session) &&
                    @phase_status != :processing
                }
                phx-click="mark_done"
                id="mark-done-btn"
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
          <div class="flex-1 min-h-0 overflow-hidden">
            {render_phase(assigns)}
          </div>

          <%!-- Exported metadata sidebar --%>
          <%= if @workflow_session do %>
            <div
              id="metadata-sidebar"
              phx-hook=".MetadataSidebar"
              class="flex flex-col border-l border-base-300 shrink-0"
            >
              <%!-- Toggle button — always visible --%>
              <button
                id="metadata-sidebar-toggle"
                class="px-2 py-3 border-b border-base-300 bg-base-100 hover:bg-base-200 transition-colors duration-150 flex items-center gap-1.5"
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
                <span class="text-xs font-medium text-base-content/40 sidebar-label-expanded">
                  Output
                </span>
              </button>

              <%!-- Sidebar content — toggled by hook --%>
              <div id="metadata-sidebar-content" class="w-80 overflow-y-auto flex-1 bg-base-100">
                <%!-- Source code section --%>
                <div
                  :if={@worktree_path}
                  class="p-4 border-b border-base-300/60"
                >
                  <div class="flex items-center gap-2 mb-3">
                    <.icon
                      name="hero-folder-open-micro"
                      class="size-4 text-base-content/30"
                    />
                    <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wide">
                      Source Code
                    </h3>
                  </div>
                  <code class="text-xs text-base-content/50 break-all leading-relaxed">
                    {@worktree_path}
                  </code>
                </div>

                <%!-- Exported metadata section --%>
                <div class="p-4">
                  <div class="flex items-center gap-2 mb-4">
                    <.icon
                      name="hero-arrow-up-tray-micro"
                      class="size-4 text-base-content/30"
                    />
                    <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wide">
                      Exported Metadata
                    </h3>
                  </div>

                  <%= if @exported_metadata == [] do %>
                    <div class="flex flex-col items-center py-8 text-center">
                      <.icon
                        name="hero-inbox-micro"
                        class="size-8 text-base-content/15 mb-2"
                      />
                      <p class="text-xs text-base-content/30">
                        No metadata exported yet
                      </p>
                    </div>
                  <% else %>
                    <div class="space-y-1.5">
                      <details
                        :for={meta <- @exported_metadata}
                        id={"metadata-entry-#{meta.id}"}
                        class="group rounded-lg border border-base-300/60 overflow-hidden"
                        open
                      >
                        <summary class="flex items-center gap-2 cursor-pointer px-3 py-2 hover:bg-base-200/50 transition-colors duration-150 text-sm select-none">
                          <.icon
                            name="hero-chevron-right-micro"
                            class="size-3 text-base-content/30 group-open:rotate-90 transition-transform duration-150 shrink-0"
                          />
                          <span class="font-medium text-base-content/70 truncate">
                            {humanize_key(meta.key)}
                          </span>
                        </summary>
                        <div class="border-t border-base-300/40 bg-base-200/30">
                          <.metadata_value_block value={meta.value} />
                        </div>
                      </details>
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
          question_answers={@question_answers}
          metadata={@metadata}
          current_step={@current_step}
          phase_status={@phase_status}
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

  defp assign_worktree_path(socket, ws_id) do
    ai_session = AI.get_ai_session_for_workflow(ws_id)
    assign(socket, :worktree_path, ai_session && ai_session.worktree_path)
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
  defp format_metadata_value(value) when is_map(value), do: Jason.encode!(value, pretty: true)
  defp format_metadata_value(value), do: inspect(value)

  defp humanize_key(key) when is_binary(key) do
    key |> String.replace("_", " ") |> String.capitalize()
  end
end
