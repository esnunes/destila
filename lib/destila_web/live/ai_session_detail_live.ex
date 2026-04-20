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

    socket =
      socket
      |> assign(:workflow_session, ws)
      |> assign(:ai_session, ai_session)
      |> assign(:alive?, AlivenessTracker.alive_ai?(ai_session.id))
      |> assign(:history_state, history_state)
      |> assign(:loaded_count, loaded_count)
      |> assign(:reload_scheduled?, false)
      |> assign(:usage_totals, AI.aggregate_usage_for_ai_session(ai_session.id))
      |> assign(:page_title, "AI Session — #{ws.title}")
      |> assign_phase_state()

    {:ok, socket}
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
      socket =
        socket
        |> assign(:usage_totals, AI.aggregate_usage_for_ai_session(ai_id))
        |> assign_phase_state()

      {:noreply, socket}
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
        new_times = Enum.map(new_entries, &parse_entry_timestamp/1)
        history_state = append_entries(socket.assigns.history_state, normalized, new_times)

        socket
        |> assign(:history_state, history_state)
        |> assign(:loaded_count, length(entries))
        |> assign_phase_state()

      {:ok, _} ->
        socket

      {:error, reason} ->
        Logger.warning("Failed to reload AI history for #{claude_session_id}: #{inspect(reason)}")

        socket
    end
  end

  defp append_entries({:loaded, existing, tool_index, entry_times}, new_items, new_times) do
    {:loaded, existing ++ new_items, Map.merge(tool_index, build_tool_index(new_items)),
     entry_times ++ new_times}
  end

  defp append_entries(_state, new_items, new_times) do
    {:loaded, new_items, build_tool_index(new_items), new_times}
  end

  defp load_history(%AI.Session{claude_session_id: nil}), do: {:missing, 0}

  defp load_history(%AI.Session{claude_session_id: claude_session_id}) do
    case History.read_all(claude_session_id) do
      {:ok, []} ->
        {:empty, 0}

      {:ok, entries} ->
        normalized = Enum.map(entries, &normalize_entry/1)
        entry_times = Enum.map(entries, &parse_entry_timestamp/1)

        {{:loaded, normalized, build_tool_index(normalized), entry_times}, length(entries)}

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

  defp parse_entry_timestamp(%_{} = _struct), do: nil

  defp parse_entry_timestamp(entry) when is_map(entry) do
    case Map.get(entry, "timestamp") do
      ts when is_binary(ts) ->
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_entry_timestamp(_), do: nil

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

        <.phase_stepper
          workflow_session={@workflow_session}
          usage_by_phase={@usage_by_phase}
          phase_wall_clocks={@phase_wall_clocks}
          clickable_phases={@clickable_phases}
        />

        <div class="flex-1 min-h-0 overflow-y-auto scroll-smooth">
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
              <% {:loaded, items, tool_index, _entry_times} -> %>
                <.session_history
                  items={merge_separators(items, @separator_targets, @workflow_session.workflow_type)}
                  tool_index={tool_index}
                />
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp assign_phase_state(socket) do
    ai_id = socket.assigns.ai_session.id
    workflow_type = socket.assigns.workflow_session.workflow_type
    total = Workflows.total_phases(workflow_type)

    usage_by_phase = AI.aggregate_usage_by_phase(ai_id)
    boundaries = AI.phase_boundaries_for_ai_session(ai_id)

    {items, entry_times} = items_and_times(socket.assigns.history_state)

    separator_targets = compute_separator_targets(items, entry_times, boundaries, total)
    phase_wall_clocks = compute_phase_wall_clocks(items, entry_times, separator_targets)
    clickable_phases = separator_targets |> Map.values() |> MapSet.new()

    socket
    |> assign(:usage_by_phase, usage_by_phase)
    |> assign(:separator_targets, separator_targets)
    |> assign(:phase_wall_clocks, phase_wall_clocks)
    |> assign(:clickable_phases, clickable_phases)
  end

  defp items_and_times({:loaded, items, _tool_index, entry_times}), do: {items, entry_times}
  defp items_and_times(_), do: {[], []}

  defp compute_separator_targets([], _entry_times, _boundaries, _total), do: %{}

  defp compute_separator_targets(items, entry_times, boundaries, total) do
    initial = if Map.has_key?(boundaries, 1), do: %{0 => 1}, else: %{}

    Enum.reduce(2..max(total, 1), initial, fn n, acc ->
      case Map.get(boundaries, n - 1) do
        %DateTime{} = boundary ->
          case first_idx_after(entry_times, boundary) do
            nil ->
              acc

            idx ->
              if Map.has_key?(acc, idx), do: acc, else: Map.put(acc, idx, n)
          end

        _ ->
          acc
      end
    end)
    |> then(fn map ->
      if items == [], do: %{}, else: map
    end)
  end

  defp first_idx_after(entry_times, boundary) do
    entry_times
    |> Enum.with_index()
    |> Enum.find_value(fn
      {%DateTime{} = dt, idx} ->
        if DateTime.compare(dt, boundary) == :gt, do: idx, else: nil

      _ ->
        nil
    end)
  end

  defp compute_phase_wall_clocks(_items, _entry_times, separator_targets)
       when map_size(separator_targets) == 0,
       do: %{}

  defp compute_phase_wall_clocks(items, entry_times, separator_targets) do
    sorted = Enum.sort_by(separator_targets, fn {idx, _phase} -> idx end)
    total_items = length(items)

    sorted
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {{start_idx, phase}, i}, acc ->
      end_idx =
        case Enum.at(sorted, i + 1) do
          {next_idx, _} -> next_idx - 1
          nil -> total_items - 1
        end

      times =
        entry_times
        |> Enum.slice(start_idx..end_idx)
        |> Enum.reject(&is_nil/1)

      case times do
        [_, _ | _] ->
          first = Enum.min_by(times, &DateTime.to_unix(&1, :millisecond))
          last = Enum.max_by(times, &DateTime.to_unix(&1, :millisecond))
          diff = DateTime.diff(last, first, :millisecond)
          Map.put(acc, phase, diff)

        _ ->
          acc
      end
    end)
  end

  defp merge_separators(items, separator_targets, _workflow_type)
       when map_size(separator_targets) == 0,
       do: items

  defp merge_separators(items, separator_targets, workflow_type) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, idx} ->
      case Map.get(separator_targets, idx) do
        nil ->
          [item]

        phase ->
          phase_name = Workflows.phase_name(workflow_type, phase)
          [{:separator, phase, phase_name}, item]
      end
    end)
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
