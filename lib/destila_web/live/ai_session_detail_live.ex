defmodule DestilaWeb.AiSessionDetailLive do
  use DestilaWeb, :live_view

  import DestilaWeb.BoardComponents, only: [aliveness_dot: 1]
  import DestilaWeb.AiSessionDebugComponents

  require Logger

  alias Destila.AI
  alias Destila.AI.AlivenessTracker
  alias Destila.AI.History
  alias Destila.PubSubHelper
  alias Destila.Workflows

  @reload_debounce_ms 500

  @impl true
  def mount(
        %{"workflow_session_id" => ws_id, "ai_session_id" => ai_id},
        _session,
        socket
      ) do
    case Workflows.get_workflow_session(ws_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Session not found")
         |> push_navigate(to: ~p"/crafting")}

      %Workflows.Session{} = ws ->
        mount_with_workflow(ws, ai_id, socket)
    end
  end

  defp mount_with_workflow(%Workflows.Session{} = ws, ai_id, socket) do
    case AI.get_ai_session(ai_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "AI session not found")
         |> push_navigate(to: ~p"/sessions/#{ws.id}")}

      %AI.Session{} = ai_session ->
        if ai_session.workflow_session_id == ws.id do
          mount_with_session(ws, ai_session, socket)
        else
          {:ok,
           socket
           |> put_flash(:error, "AI session does not belong to this workflow")
           |> push_navigate(to: ~p"/sessions/#{ws.id}")}
        end
    end
  end

  defp mount_with_session(%Workflows.Session{} = ws, %AI.Session{} = ai_session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Destila.PubSub, AlivenessTracker.topic())
      Phoenix.PubSub.subscribe(Destila.PubSub, PubSubHelper.ai_stream_topic(ws.id))
    end

    history_state = load_history(ai_session)

    {:ok,
     socket
     |> assign(:workflow_session, ws)
     |> assign(:ai_session, ai_session)
     |> assign(:alive?, AlivenessTracker.alive_ai?(ai_session.id))
     |> assign(:history_state, history_state)
     |> assign(:loaded_count, history_loaded_count(history_state))
     |> assign(:reload_scheduled?, false)
     |> assign(:page_title, "AI Session — #{ws.title}")}
  end

  @impl true
  def handle_info({:aliveness_changed_ai, ai_id, alive?}, socket) do
    if socket.assigns.ai_session.id == ai_id do
      {:noreply, assign(socket, :alive?, alive?)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:ai_stream_chunk, _item}, socket) do
    {:noreply, maybe_schedule_reload(socket)}
  end

  def handle_info(:reload_history, socket) do
    {:noreply, refresh_history(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp maybe_schedule_reload(socket) do
    cond do
      socket.assigns.reload_scheduled? ->
        socket

      is_nil(socket.assigns.ai_session.claude_session_id) ->
        socket

      true ->
        Process.send_after(self(), :reload_history, @reload_debounce_ms)
        assign(socket, :reload_scheduled?, true)
    end
  end

  defp refresh_history(socket) do
    socket = assign(socket, :reload_scheduled?, false)
    claude_session_id = socket.assigns.ai_session.claude_session_id
    offset = socket.assigns.loaded_count

    case History.get_messages(claude_session_id, offset: offset) do
      {:ok, []} ->
        socket

      {:ok, new_messages} ->
        history_state = append_messages(socket.assigns.history_state, new_messages)

        socket
        |> assign(:history_state, history_state)
        |> assign(:loaded_count, offset + length(new_messages))

      {:error, reason} ->
        Logger.warning("Failed to reload AI history for #{claude_session_id}: #{inspect(reason)}")

        socket
    end
  end

  defp append_messages({:loaded, existing, tool_index}, new_messages) do
    {:loaded, existing ++ new_messages, Map.merge(tool_index, build_tool_index(new_messages))}
  end

  defp append_messages(_state, new_messages) do
    {:loaded, new_messages, build_tool_index(new_messages)}
  end

  defp history_loaded_count({:loaded, messages, _tool_index}), do: length(messages)
  defp history_loaded_count(_), do: 0

  defp load_history(%AI.Session{claude_session_id: nil}), do: :missing

  defp load_history(%AI.Session{claude_session_id: claude_session_id}) do
    case History.get_messages(claude_session_id) do
      {:ok, []} ->
        :empty

      {:ok, messages} ->
        {:loaded, messages, build_tool_index(messages)}

      {:error, reason} ->
        Logger.warning("Failed to load AI history for #{claude_session_id}: #{inspect(reason)}")
        :error
    end
  end

  defp build_tool_index(messages) do
    Enum.reduce(messages, %{}, fn msg, acc ->
      content =
        case Map.get(msg, :message) do
          %{content: content} -> content
          %{"content" => content} -> content
          _ -> []
        end

      content
      |> List.wrap()
      |> Enum.reduce(acc, fn
        %ClaudeCode.Content.ToolUseBlock{id: id} = block, inner -> Map.put(inner, id, block)
        %ClaudeCode.Content.ServerToolUseBlock{id: id} = block, inner -> Map.put(inner, id, block)
        %ClaudeCode.Content.MCPToolUseBlock{id: id} = block, inner -> Map.put(inner, id, block)
        _, inner -> inner
      end)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title}>
      <div class="flex flex-col h-screen bg-base-200">
        <div
          id="ai-session-header"
          class="flex items-center gap-3 px-4 py-2.5 border-b border-base-300 bg-base-100 shrink-0"
        >
          <.link
            id="ai-session-back-link"
            navigate={~p"/sessions/#{@workflow_session.id}"}
            class="btn btn-ghost btn-sm btn-square"
          >
            <.icon name="hero-arrow-left-micro" class="size-4" />
          </.link>
          <div class="flex items-center gap-2 min-w-0 flex-1">
            <.aliveness_dot
              session={@workflow_session}
              alive?={@alive?}
              phase_status={:idle}
            />
            <.icon name="hero-cpu-chip-micro" class="size-4 text-base-content/40 shrink-0" />
            <span class="text-sm font-medium text-base-content/80 truncate">
              {@workflow_session.title}
            </span>
            <span class="text-xs text-base-content/40 shrink-0">
              {format_inserted_at(@ai_session.inserted_at)}
            </span>
            <code
              :if={@ai_session.claude_session_id}
              id="ai-session-claude-id"
              class="text-xs text-base-content/50 font-mono truncate"
            >
              {@ai_session.claude_session_id}
            </code>
          </div>
        </div>

        <div class="flex-1 min-h-0 overflow-y-auto">
          <div id="ai-session-conversation" class="max-w-3xl mx-auto py-6 px-4 space-y-4">
            <%= case @history_state do %>
              <% :missing -> %>
                <.empty_state
                  icon="hero-inbox-micro"
                  title="No conversation history available"
                  detail="This AI session hasn't been linked to a Claude session yet."
                />
              <% :empty -> %>
                <.empty_state
                  icon="hero-inbox-micro"
                  title="No conversation history available"
                  detail="The session file exists but has no visible messages."
                />
              <% :error -> %>
                <.empty_state
                  icon="hero-exclamation-triangle-micro"
                  title="Unable to read conversation history"
                  detail="See server logs for details."
                />
              <% {:loaded, messages, tool_index} -> %>
                <.session_history messages={messages} tool_index={tool_index} />
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :detail, :string, required: true

  defp empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center py-16 text-center">
      <.icon name={@icon} class="size-8 text-base-content/20 mb-3" />
      <p class="text-sm font-medium text-base-content/60">{@title}</p>
      <p class="text-xs text-base-content/40 mt-1">{@detail}</p>
    </div>
    """
  end

  defp format_inserted_at(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %-d, %Y %H:%M")
  end

  defp format_inserted_at(_), do: ""
end
