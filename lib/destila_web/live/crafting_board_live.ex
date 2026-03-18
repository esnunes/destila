defmodule DestilaWeb.CraftingBoardLive do
  use DestilaWeb, :live_view

  import DestilaWeb.BoardComponents

  @columns [:request, :distill, :done]

  def mount(_params, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
    end

    prompts = Destila.Store.list_prompts(:crafting)

    {:ok,
     socket
     |> assign(:current_user, session["current_user"])
     |> assign(:page_title, "Prompt Crafting")
     |> assign(:columns, @columns)
     |> assign_columns(prompts)}
  end

  def handle_event("card_moved", %{"id" => id, "to" => to_column, "index" => index}, socket) do
    column = String.to_existing_atom(to_column)
    Destila.Store.move_card(id, column, index)
    prompts = Destila.Store.list_prompts(:crafting)
    {:noreply, assign_columns(socket, prompts)}
  end

  def handle_info({_event, _data}, socket) do
    prompts = Destila.Store.list_prompts(:crafting)
    {:noreply, assign_columns(socket, prompts)}
  end

  defp assign_columns(socket, prompts) do
    grouped = Enum.group_by(prompts, & &1.column)

    Enum.reduce(@columns, socket, fn col, acc ->
      assign(acc, col, Map.get(grouped, col, []))
    end)
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="p-6 lg:p-8">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-2xl font-bold tracking-tight">Prompt Crafting</h1>
          <.link navigate={~p"/prompts/new"} class="btn btn-primary btn-sm">
            <.icon name="hero-plus-micro" class="size-4" /> New Prompt
          </.link>
        </div>

        <div class="flex gap-4 overflow-x-auto pb-4" data-board-group="crafting">
          <.board_column
            :for={col <- @columns}
            title={Atom.to_string(col)}
            column={col}
            cards={assigns[col]}
            id={"crafting-#{col}"}
            sortable
          />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
