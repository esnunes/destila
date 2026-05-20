defmodule DestilaWeb.AgentSessionLive do
  @moduledoc """
  Backs `/agent-sessions/:id`. Export-first layout: exports panel headline,
  collapsible tool-call event log secondary, agent surface (xterm.js embedded
  or external host panel) and a question panel when one is pending.

  No chat textarea. No assistant-text storage. All updates are driven by
  PubSub events from `Destila.Agent.SessionServer`.
  """

  use DestilaWeb, :live_view

  alias Destila.Agent.{Sessions, SessionServer, ExternalHost}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Sessions.get_session(id) do
      nil ->
        {:ok, redirect(socket, to: ~p"/crafting")}

      session ->
        if connected?(socket) do
          Sessions.subscribe(id)
          _ = SessionServer.ensure_started(id)
        end

        events = Sessions.list_events(id)
        exports = Sessions.list_exports(id)

        connection_info =
          if session.host_mode == :external,
            do: ExternalHost.connection_info(id),
            else: nil

        {:ok,
         socket
         |> assign(:page_title, "Agent Session")
         |> assign(:session, session)
         |> assign(:connection_info, connection_info)
         |> assign(:pending_question, nil)
         |> assign(:answered_questions, MapSet.new())
         |> assign(:pending_handoff_message, nil)
         |> assign(:paste_target, nil)
         |> assign(:event_log_open, false)
         |> stream(:events, events)
         |> stream(:exports, exports)
         |> assign(:exports_empty?, exports == [])}
    end
  end

  @impl true
  def handle_event("toggle_event_log", _, socket) do
    {:noreply, update(socket, :event_log_open, &(not &1))}
  end

  def handle_event(
        "answer_question",
        %{"question_id" => question_id, "value" => value},
        socket
      ) do
    :ok = SessionServer.answer_question(socket.assigns.session.id, question_id, value)

    {:noreply,
     socket
     |> assign(:pending_question, nil)
     |> update(:answered_questions, &MapSet.put(&1, question_id))}
  end

  def handle_event("confirm_phase_complete", _, socket) do
    {:noreply, assign(socket, :pending_handoff_message, nil)}
  end

  def handle_event("dismiss_handoff", _, socket) do
    {:noreply, assign(socket, :pending_handoff_message, nil)}
  end

  def handle_event("terminal_input", %{"data" => _data}, socket) do
    # Forwarded by the xterm.js hook; in embedded mode the terminal Server
    # already owns the PTY, so this is currently a no-op stub.
    {:noreply, socket}
  end

  @impl true
  def handle_info({:export_added, meta}, socket) do
    {:noreply,
     socket
     |> stream_insert(:exports, meta)
     |> assign(:exports_empty?, false)}
  end

  def handle_info({:tool_call_event, event}, socket) do
    {:noreply, stream_insert(socket, :events, event)}
  end

  def handle_info({:phase_advanced, _new_index}, socket) do
    session = Sessions.get_session(socket.assigns.session.id)
    {:noreply, assign(socket, :session, session)}
  end

  def handle_info({:suggest_phase_complete, message}, socket) do
    {:noreply, assign(socket, :pending_handoff_message, message)}
  end

  def handle_info({:question_asked, %{question_id: qid, questions: questions}}, socket) do
    {:noreply, assign(socket, :pending_question, %{question_id: qid, questions: questions})}
  end

  def handle_info({:question_answered, _question_id, _value}, socket) do
    {:noreply, socket}
  end

  def handle_info({:paste_target, paste}, socket) do
    {:noreply, assign(socket, :paste_target, paste)}
  end

  def handle_info({:agent_connected, session}, socket) do
    {:noreply, assign(socket, :session, session)}
  end

  def handle_info({:agent_disconnected, session}, socket) do
    {:noreply, assign(socket, :session, session)}
  end

  def handle_info({:agent_session_updated, session}, socket) do
    {:noreply, assign(socket, :session, session)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title}>
      <div class="p-6 lg:p-8 space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold tracking-tight">
              Agent session
            </h1>
            <p class="text-sm text-base-content/60">
              {@session.workflow_name} ·
              Phase {@session.current_phase_index + 1} of {@session.total_phases} ·
              <span id="agent-status">
                {agent_status_label(@session.status)}
              </span>
            </p>
          </div>
        </div>

        <%!-- Exports panel (primary) --%>
        <section id="exports-panel" class="bg-base-200/40 rounded-xl p-5 border border-base-300/50">
          <div class="flex items-center justify-between mb-3">
            <h2 class="text-lg font-semibold">Exports</h2>
          </div>

          <div
            :if={@exports_empty?}
            id="exports-empty-placeholder"
            class="text-sm text-base-content/40 italic"
          >
            Nothing exported yet. As the agent exports artifacts, they appear here.
          </div>

          <ul id="exports-list" phx-update="stream" class="space-y-2">
            <li :for={{id, meta} <- @streams.exports} id={id} class="bg-base-100 p-3 rounded-lg">
              <div class="flex items-center justify-between gap-2">
                <div class="font-medium text-sm">{meta.key}</div>
                <div class="text-xs text-base-content/50">{meta.phase_name}</div>
              </div>
              <pre class="mt-2 text-xs whitespace-pre-wrap break-words text-base-content/80"><%= render_export_value(meta) %></pre>
            </li>
          </ul>
        </section>

        <%!-- Agent surface --%>
        <%= if @session.host_mode == :embedded do %>
          <section
            id="embedded-terminal"
            phx-hook="TerminalPanel"
            phx-update="ignore"
            class="bg-base-300 rounded-xl h-96"
          >
          </section>
        <% else %>
          <section
            id="external-host-panel"
            class="bg-base-200/40 rounded-xl p-5 border border-base-300/50 space-y-3"
          >
            <h2 class="text-lg font-semibold">External agent connection</h2>
            <div class="text-sm space-y-2">
              <div>
                <span class="text-base-content/60">Bridge binary:</span>
                <code id="external-bridge-path">{@connection_info.bridge_path}</code>
              </div>
              <div>
                <span class="text-base-content/60">MCP URL:</span>
                <code id="external-mcp-url">{@connection_info.mcp_url}</code>
              </div>
              <div>
                <span class="text-base-content/60">Token:</span>
                <code id="external-token">{@connection_info.token}</code>
              </div>
              <div>
                <span class="text-base-content/60">Session id (set as DESTILA_SESSION_ID):</span>
                <code id="external-session-id">{@connection_info.session_id}</code>
              </div>
            </div>

            <div :if={@paste_target} id="paste-target-card" class="mt-3 bg-base-100 p-3 rounded-lg">
              <div class="text-xs uppercase text-base-content/50 mb-1">
                Paste into your agent ({@paste_target.kind})
              </div>
              <pre class="text-xs whitespace-pre-wrap break-words"><%= @paste_target.value %></pre>
            </div>
          </section>
        <% end %>

        <%!-- Pending question panel --%>
        <section
          :if={@pending_question}
          id="question-panel"
          class="bg-warning/10 border border-warning/30 rounded-xl p-5 space-y-3"
        >
          <h2 class="text-lg font-semibold">Agent asked a question</h2>
          <div :for={question <- @pending_question.questions} class="space-y-2">
            <div class="text-sm font-medium">{Map.get(question, "question")}</div>
            <div class="flex flex-wrap gap-2">
              <button
                :for={option <- Map.get(question, "options", [])}
                phx-click="answer_question"
                phx-value-question_id={@pending_question.question_id}
                phx-value-value={Map.get(option, "label")}
                class="btn btn-sm btn-outline"
              >
                {Map.get(option, "label")}
              </button>
            </div>
          </div>
        </section>

        <%!-- Phase handoff modal --%>
        <section
          :if={@pending_handoff_message}
          id="phase-handoff-modal"
          class="bg-info/10 border border-info/30 rounded-xl p-5"
        >
          <h2 class="text-lg font-semibold mb-2">Confirm phase transition</h2>
          <p class="text-sm mb-3">{@pending_handoff_message}</p>
          <div class="flex gap-2">
            <button phx-click="confirm_phase_complete" class="btn btn-sm btn-primary">
              Confirm
            </button>
            <button phx-click="dismiss_handoff" class="btn btn-sm btn-ghost">
              Dismiss
            </button>
          </div>
        </section>

        <%!-- Event log (secondary, collapsible) --%>
        <section id="event-log-panel" class="bg-base-200/30 rounded-xl border border-base-300/50">
          <button
            phx-click="toggle_event_log"
            class="w-full text-left p-3 text-sm font-medium flex items-center justify-between"
          >
            <span>Tool-call event log</span>
            <span class="text-xs text-base-content/50">
              {if @event_log_open, do: "▾", else: "▸"}
            </span>
          </button>

          <div :if={@event_log_open} class="p-3 border-t border-base-300/50">
            <ul id="event-log-items" phx-update="stream" class="space-y-1">
              <li
                :for={{id, event} <- @streams.events}
                id={id}
                class="text-xs text-base-content/70 font-mono"
              >
                [{event.phase_index}] {event.tool_name}
              </li>
            </ul>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp agent_status_label(:awaiting_agent), do: "Awaiting agent"
  defp agent_status_label(:active), do: "Active"
  defp agent_status_label(:disconnected), do: "Not connected"
  defp agent_status_label(:done), do: "Completed"
  defp agent_status_label(_), do: "Unknown"

  defp render_export_value(%{value: nil}), do: ""
  defp render_export_value(%{value: %{} = v}), do: Map.get(v, "value", inspect(v))
  defp render_export_value(meta), do: inspect(meta.value)
end
