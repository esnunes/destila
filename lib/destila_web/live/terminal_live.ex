defmodule DestilaWeb.TerminalLive do
  use DestilaWeb, :live_view

  alias Destila.AI

  @cols 125
  @rows 30

  def mount(%{"id" => ws_id}, _session, socket) do
    ai_session = AI.get_ai_session_for_workflow(ws_id)
    worktree_path = ai_session && ai_session.worktree_path

    if worktree_path do
      ws = Destila.Workflows.get_workflow_session!(ws_id)

      socket =
        socket
        |> assign(:ws_id, ws_id)
        |> assign(:page_title, "Terminal — #{ws.title}")
        |> assign(:worktree_path, worktree_path)
        |> assign(:session_title, ws.title)
        |> assign(:claude_session_id, ai_session.claude_session_id)
        |> assign(:term, nil)
        |> assign(:pty, nil)

      if connected?(socket) do
        {:ok, start_session(socket)}
      else
        {:ok, socket}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "No worktree path for this session")
       |> push_navigate(to: ~p"/sessions/#{ws_id}")}
    end
  end

  def handle_info({:terminal_ready, _id, _cols, _rows}, socket), do: {:noreply, socket}

  def handle_info({:data, data}, socket) do
    Ghostty.Terminal.write(socket.assigns.term, data)
    send_update(DestilaWeb.TerminalComponent, id: "terminal", refresh: true)
    {:noreply, socket}
  end

  def handle_info({:exit, _status}, socket) do
    {:noreply, assign(socket, :pty, nil)}
  end

  def handle_info({:pty_write, data}, %{assigns: %{pty: pty}} = socket) when not is_nil(pty) do
    Ghostty.PTY.write(pty, data)
    {:noreply, socket}
  end

  def handle_info({:pty_write, _data}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  def terminate(_reason, socket) do
    if pty = socket.assigns[:pty], do: safe_stop(pty)
    if term = socket.assigns[:term], do: safe_stop(term)
    :ok
  catch
    :exit, _ -> :ok
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-center justify-center h-screen bg-base-100">
        <div class="terminal-window">
          <div class="terminal-header">
            <.link
              navigate={~p"/sessions/#{@ws_id}"}
              class="text-base-content/50 hover:text-base-content transition-colors"
            >
              <.icon name="hero-arrow-left-micro" class="size-4" />
            </.link>
            <code class="text-xs text-base-content/40 truncate flex-1">{@worktree_path}</code>
          </div>
          <%= if @term do %>
            <.live_component
              module={DestilaWeb.TerminalComponent}
              id="terminal"
              term={@term}
              pty={@pty}
              fit={false}
              autofocus={true}
              class="terminal-view"
              bg="#eff1f5"
              fg="#4c4f69"
            />
          <% else %>
            <div class="terminal-placeholder">Connecting...</div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Catppuccin Latte palette (OSC 4 sequences to remap the NIF's default Mocha colors)
  @latte_palette [
    {0, "#5c5f77"},
    {1, "#d20f39"},
    {2, "#40a02b"},
    {3, "#df8e1d"},
    {4, "#1e66f5"},
    {5, "#ea76cb"},
    {6, "#179299"},
    {7, "#acb0be"},
    {8, "#6c6f85"},
    {9, "#d20f39"},
    {10, "#40a02b"},
    {11, "#df8e1d"},
    {12, "#1e66f5"},
    {13, "#ea76cb"},
    {14, "#179299"},
    {15, "#bcc0cc"}
  ]

  defp start_session(socket) do
    {:ok, term} = Ghostty.Terminal.start_link(cols: @cols, rows: @rows)
    apply_palette(term)

    {:ok, pty} =
      start_pty(
        socket.assigns.session_title,
        socket.assigns.worktree_path,
        socket.assigns.claude_session_id,
        @cols,
        @rows
      )

    socket
    |> assign(:term, term)
    |> assign(:pty, pty)
  end

  defp start_pty(session_title, worktree_path, claude_session_id, cols, rows) do
    session = shell_escape(session_title)
    dir = shell_escape(worktree_path)

    attach = "tmux attach -t #{session}"

    create =
      if claude_session_id do
        claude_cmd = build_claude_resume_cmd(claude_session_id)

        claude_window_cmd =
          "clear && echo '# run the following command to resume the claude code session:' && " <>
            "echo '# #{claude_cmd}' && exec $SHELL"

        "tmux new-session -s #{session} -n shell -c #{dir} \\; " <>
          "new-window -n 'claude code' -c #{dir} #{shell_escape(claude_window_cmd)} \\; " <>
          "select-window -t 1"
      else
        "tmux new-session -s #{session} -n shell -c #{dir}"
      end

    script = "tmux has-session -t #{session} 2>/dev/null && #{attach} || #{create}"

    Ghostty.PTY.start_link(
      cmd: "/usr/bin/env",
      args: ["TERM=xterm-256color", "COLORTERM=truecolor", "/bin/sh", "-c", script],
      cols: cols,
      rows: rows
    )
  end

  defp build_claude_resume_cmd(session_id) do
    parts = ["claude --resume #{session_id}"]

    parts =
      case ClaudeCode.Plugin.list() do
        {:ok, plugins} ->
          plugins
          |> Enum.filter(&(&1.enabled && &1.install_path))
          |> Enum.reduce(parts, fn plugin, acc ->
            acc ++ ["--plugin-dir #{plugin.install_path}"]
          end)

        _ ->
          parts
      end

    parts = parts ++ ["--setting-sources user,project"]

    Enum.join(parts, " ")
  end

  defp safe_stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  defp apply_palette(term) do
    osc =
      Enum.map_join(@latte_palette, fn {idx, color} ->
        "\e]4;#{idx};#{color}\e\\"
      end)

    Ghostty.Terminal.write(term, osc)
  end

  defp shell_escape(str), do: "'" <> String.replace(str, "'", "'\\''") <> "'"
end
