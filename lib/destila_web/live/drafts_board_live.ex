defmodule DestilaWeb.DraftsBoardLive do
  @moduledoc """
  Priority-based kanban board of drafts at /drafts.

  Three columns: High, Medium, Low. Cards are clickable and navigate to
  the draft detail page. Drag-and-drop is handled by the `DraftsBoard`
  JS hook which pushes a `reorder_draft` event.
  """

  use DestilaWeb, :live_view

  require Logger

  alias Destila.Drafts

  @priorities [:high, :medium, :low]

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")

    grouped = Drafts.list_all_active()

    {:ok,
     socket
     |> assign(:page_title, "Drafts")
     |> assign_board(grouped)}
  end

  def handle_info({event, _data}, socket)
      when event in [:draft_created, :draft_updated] do
    grouped = Drafts.list_all_active()

    socket =
      socket
      |> reset_streams(grouped)
      |> assign_board_flags(grouped)

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  def handle_event(
        "reorder_draft",
        %{"draft_id" => draft_id, "priority" => priority_str} = params,
        socket
      ) do
    with {:ok, priority} <- cast_priority(priority_str),
         draft when not is_nil(draft) <- Drafts.get_draft(draft_id) do
      before_id = empty_to_nil(params["before_id"])
      after_id = empty_to_nil(params["after_id"])

      case Drafts.reposition_draft(draft, priority, before_id, after_id) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("reposition_draft failed: #{inspect(reason)} draft_id=#{draft_id}")
      end
    end

    {:noreply, socket}
  end

  defp cast_priority(str) when is_binary(str) do
    case String.to_existing_atom(str) do
      atom when atom in @priorities -> {:ok, atom}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp cast_priority(_), do: :error

  defp empty_to_nil(nil), do: nil
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(id), do: id

  defp assign_board(socket, grouped) do
    Enum.reduce(@priorities, socket, fn priority, acc ->
      stream(acc, stream_key(priority), Map.get(grouped, priority, []))
    end)
    |> assign_board_flags(grouped)
  end

  defp reset_streams(socket, grouped) do
    Enum.reduce(@priorities, socket, fn priority, acc ->
      stream(acc, stream_key(priority), Map.get(grouped, priority, []), reset: true)
    end)
  end

  defp assign_board_flags(socket, grouped) do
    any? = Enum.any?(@priorities, fn p -> Map.get(grouped, p, []) != [] end)
    assign(socket, :any_drafts?, any?)
  end

  defp stream_key(:high), do: :drafts_high
  defp stream_key(:medium), do: :drafts_medium
  defp stream_key(:low), do: :drafts_low

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title}>
      <div class="p-6 lg:p-8">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-2xl font-bold tracking-tight">Drafts</h1>
          <.link navigate={~p"/drafts/new"} class="btn btn-primary btn-sm" id="new-draft-btn">
            <.icon name="hero-plus-micro" class="size-4" /> New Draft
          </.link>
        </div>

        <%= if @any_drafts? do %>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
            <.column
              priority={:high}
              label="High"
              stream={@streams.drafts_high}
              accent="text-error"
            />
            <.column
              priority={:medium}
              label="Medium"
              stream={@streams.drafts_medium}
              accent="text-warning"
            />
            <.column
              priority={:low}
              label="Low"
              stream={@streams.drafts_low}
              accent="text-base-content/50"
            />
          </div>
        <% else %>
          <div class="text-center py-20" id="drafts-board-empty">
            <.icon name="hero-document-text" class="size-12 text-base-content/20 mx-auto mb-3" />
            <p class="text-sm text-base-content/40 mb-4">
              No drafts yet — capture your first idea.
            </p>
            <.link
              navigate={~p"/drafts/new"}
              class="btn btn-primary"
              id="create-first-draft-btn"
            >
              <.icon name="hero-plus-micro" class="size-4" /> Create your first draft
            </.link>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :priority, :atom, required: true
  attr :label, :string, required: true
  attr :stream, :any, required: true
  attr :accent, :string, default: ""

  defp column(assigns) do
    ~H"""
    <div
      id={"column-#{@priority}"}
      phx-hook="DraftsBoard"
      data-priority={@priority}
      class="bg-base-200/40 rounded-lg p-3 flex flex-col gap-2 min-h-[12rem]"
    >
      <header class="flex items-center gap-2 px-1 pb-2 border-b border-base-300/50">
        <span class={["text-sm font-semibold tracking-tight", @accent]}>{@label}</span>
      </header>

      <div id={"drafts-#{@priority}"} phx-update="stream" class="space-y-2 min-h-[2rem]">
        <div :for={{id, draft} <- @stream} id={id} data-draft-id={draft.id}>
          <.link
            navigate={~p"/drafts/#{draft.id}"}
            draggable="true"
            class="block p-3 rounded-lg bg-base-100 shadow-sm hover:shadow-md transition-shadow cursor-pointer"
          >
            <p class="text-sm line-clamp-3 whitespace-pre-wrap">{draft.prompt}</p>
            <div class="flex items-center gap-1 mt-2 text-xs text-base-content/40">
              <.icon name="hero-folder-micro" class="size-3.5" />
              <span class="truncate">{draft.project.name}</span>
              <span :if={draft.project.archived_at} class="ml-1 text-warning">
                (archived)
              </span>
            </div>
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
