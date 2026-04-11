# Temporary local copy of Ghostty.LiveTerminal.Component with key fix.
# Remove once ghostty_ex merges https://github.com/dannote/ghostty_ex/pull/2
defmodule DestilaWeb.TerminalComponent do
  use Phoenix.LiveComponent

  def update(assigns, socket) do
    first_mount? = not Map.has_key?(socket.assigns, :term)

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:pty, fn -> nil end)
      |> assign_new(:cols, fn -> 80 end)
      |> assign_new(:rows, fn -> 24 end)
      |> assign_new(:fit, fn -> false end)
      |> assign_new(:autofocus, fn -> false end)
      |> assign_new(:class, fn -> "" end)
      |> assign_new(:bg, fn -> nil end)
      |> assign_new(:fg, fn -> nil end)

    socket =
      if first_mount? or assigns[:refresh] do
        push_render(socket)
      else
        socket
      end

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class={@class}
      phx-hook="DestilaTerminal"
      phx-update="ignore"
      phx-target={@myself}
      data-cols={@cols}
      data-rows={@rows}
      data-fit={to_string(@fit)}
      data-autofocus={to_string(@autofocus)}
      data-bg={@bg}
      data-fg={@fg}
      style="font-family: monospace; line-height: 16px; font-weight: 600; -webkit-font-smoothing: auto;"
    >
      <textarea data-ghostty-input="true" autofocus={@autofocus} aria-label="Terminal input"></textarea>
    </div>
    """
  end

  # Patched: fall back to writing utf8 directly to PTY for unrecognized keys
  def handle_event("key", %{"key" => key} = params, socket) do
    case Ghostty.LiveTerminal.handle_key(socket.assigns.term, params) do
      {:ok, data} ->
        write_data(socket, data)

      :none when byte_size(key) == 1 ->
        write_data(socket, key)

      :none ->
        :ok
    end

    {:noreply, push_render(socket)}
  end

  def handle_event("text", %{"data" => data}, socket) when is_binary(data) do
    if data != "" do
      if socket.assigns.pty do
        Ghostty.PTY.write(socket.assigns.pty, data)
      else
        Ghostty.LiveTerminal.handle_text(socket.assigns.term, data)
      end
    end

    {:noreply, push_render(socket)}
  end

  def handle_event("mouse", params, socket) do
    case Ghostty.LiveTerminal.handle_mouse(socket.assigns.term, params) do
      {:ok, data} -> write_data(socket, data)
      :none -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("ready", %{"cols" => cols, "rows" => rows}, socket) do
    cols = parse_dimension!(cols)
    rows = parse_dimension!(rows)

    Ghostty.Terminal.resize(socket.assigns.term, cols, rows)
    send(self(), {:terminal_ready, socket.assigns.id, cols, rows})

    {:noreply,
     socket
     |> assign(cols: cols, rows: rows)
     |> push_render()}
  end

  def handle_event("resize", %{"cols" => cols, "rows" => rows}, socket) do
    cols = parse_dimension!(cols)
    rows = parse_dimension!(rows)

    Ghostty.LiveTerminal.handle_resize(socket.assigns.term, cols, rows, socket.assigns.pty)

    {:noreply,
     socket
     |> assign(cols: cols, rows: rows)
     |> push_render()}
  end

  def handle_event("focus", %{"focused" => _focused}, socket) do
    {:noreply, push_render(socket)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, push_render(socket)}
  end

  defp write_data(socket, data) do
    if socket.assigns.pty do
      Ghostty.PTY.write(socket.assigns.pty, data)
    else
      Ghostty.Terminal.write(socket.assigns.term, data)
    end
  end

  defp push_render(socket) do
    term = socket.assigns.term

    if is_pid(term) and Process.alive?(term) do
      Ghostty.LiveTerminal.push_render(socket, socket.assigns.id, term)
    else
      socket
    end
  end

  defp parse_dimension!(value) when is_integer(value) and value > 0, do: value

  defp parse_dimension!(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> raise ArgumentError, "invalid terminal dimension: #{inspect(value)}"
    end
  end
end
