defmodule DestilaWeb.AiSessionDetailLive do
  use DestilaWeb, :live_view

  import DestilaWeb.BoardComponents, only: [aliveness_dot: 1]
  import DestilaWeb.AiSessionDebugComponents

  require Logger

  alias ClaudeCode.History.SessionMessage
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
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
    end

    {history_state, loaded_count} = load_history(ai_session)

    {:ok,
     socket
     |> assign(:workflow_session, ws)
     |> assign(:ai_session, ai_session)
     |> assign(:alive?, AlivenessTracker.alive_ai?(ai_session.id))
     |> assign(:history_state, history_state)
     |> assign(:loaded_count, loaded_count)
     |> assign(:reload_scheduled?, false)
     |> assign(:usage_totals, AI.aggregate_usage_for_ai_session(ai_session.id))
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

  def handle_info({:message_added, %Destila.AI.Message{ai_session_id: ai_id}}, socket) do
    if socket.assigns.ai_session.id == ai_id do
      {:noreply, assign(socket, :usage_totals, AI.aggregate_usage_for_ai_session(ai_id))}
    else
      {:noreply, socket}
    end
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
    loaded = socket.assigns.loaded_count

    case History.read_all(claude_session_id) do
      {:ok, entries} when length(entries) > loaded ->
        new_entries = Enum.drop(entries, loaded)
        normalized = Enum.map(new_entries, &normalize_entry/1)
        history_state = append_entries(socket.assigns.history_state, normalized)

        socket
        |> assign(:history_state, history_state)
        |> assign(:loaded_count, length(entries))

      {:ok, _} ->
        socket

      {:error, reason} ->
        Logger.warning("Failed to reload AI history for #{claude_session_id}: #{inspect(reason)}")

        socket
    end
  end

  defp append_entries({:loaded, existing, tool_index}, new_items) do
    {:loaded, existing ++ new_items, Map.merge(tool_index, build_tool_index(new_items))}
  end

  defp append_entries(_state, new_items) do
    {:loaded, new_items, build_tool_index(new_items)}
  end

  defp load_history(%AI.Session{claude_session_id: nil}), do: {:missing, 0}

  defp load_history(%AI.Session{claude_session_id: claude_session_id}) do
    case History.read_all(claude_session_id) do
      {:ok, []} ->
        {:empty, 0}

      {:ok, entries} ->
        normalized = Enum.map(entries, &normalize_entry/1)
        {{:loaded, normalized, build_tool_index(normalized)}, length(entries)}

      {:error, reason} ->
        Logger.warning("Failed to load AI history for #{claude_session_id}: #{inspect(reason)}")
        {:error, 0}
    end
  end

  defp normalize_entry(%SessionMessage{} = msg), do: {:msg, msg}

  defp normalize_entry(entry) when is_map(entry) do
    case entry["type"] do
      t when t in ["user", "assistant"] -> {:msg, SessionMessage.from_entry(entry)}
      _ -> {:meta, entry}
    end
  end

  defp build_tool_index(items) do
    Enum.reduce(items, %{}, fn
      {:msg, %SessionMessage{message: message}}, acc ->
        content =
          case message do
            %{content: c} -> c
            %{"content" => c} -> c
            _ -> []
          end

        content
        |> List.wrap()
        |> Enum.reduce(acc, fn
          %ClaudeCode.Content.ToolUseBlock{id: id} = block, inner ->
            Map.put(inner, id, block)

          %ClaudeCode.Content.ServerToolUseBlock{id: id} = block, inner ->
            Map.put(inner, id, block)

          %ClaudeCode.Content.MCPToolUseBlock{id: id} = block, inner ->
            Map.put(inner, id, block)

          _, inner ->
            inner
        end)

      _, acc ->
        acc
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
            <.usage_totals_strip :if={@usage_totals.turns > 0} totals={@usage_totals} />
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
              <% {:loaded, items, tool_index} -> %>
                <.session_history items={items} tool_index={tool_index} />
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

  attr :totals, :map, required: true

  defp usage_totals_strip(assigns) do
    ~H"""
    <span
      id="ai-session-usage-totals"
      data-usage-totals
      class="ml-auto inline-flex items-center gap-1.5 rounded-full border border-base-300 bg-base-200/60 px-2 py-0.5 text-[10px] font-mono text-base-content/60 shrink-0"
      title={usage_totals_tooltip(@totals)}
    >
      <.icon name="hero-chart-bar-micro" class="size-3 text-base-content/40" />
      <span data-totals-turns>{@totals.turns} {pluralize(@totals.turns, "turn", "turns")}</span>
      <span class="text-base-content/30">·</span>
      <span data-totals-in>in {@totals.input_tokens}</span>
      <span class="text-base-content/30">·</span>
      <span data-totals-out>out {@totals.output_tokens}</span>
      <span :if={@totals.total_cost_usd > 0} class="text-base-content/30">·</span>
      <span :if={@totals.total_cost_usd > 0} data-totals-cost>
        {format_cost(@totals.total_cost_usd)}
      </span>
    </span>
    """
  end

  defp usage_totals_tooltip(totals) do
    [
      "turns: #{totals.turns}",
      "input: #{totals.input_tokens}",
      "output: #{totals.output_tokens}",
      "cache read: #{totals.cache_read_input_tokens}",
      "cache write: #{totals.cache_creation_input_tokens}",
      "cost: #{format_cost(totals.total_cost_usd)}",
      "duration: #{Float.round(totals.duration_ms / 1000, 2)}s"
    ]
    |> Enum.join(" · ")
  end

  defp format_cost(usd) when is_float(usd) do
    :erlang.float_to_binary(usd, decimals: 4)
    |> then(&("$" <> &1))
  end

  defp format_cost(_), do: "$0.0000"

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_, _singular, plural), do: plural
end
