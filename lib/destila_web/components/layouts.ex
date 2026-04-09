defmodule DestilaWeb.Layouts do
  use DestilaWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :page_title, :string, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100">
      <.sidebar page_title={@page_title} />

      <main class="min-h-screen transition-[margin-left] duration-200 ml-16 sidebar-open:ml-60">
        {render_slot(@inner_block)}
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :page_title, :string, default: nil

  defp sidebar(assigns) do
    ~H"""
    <aside class="fixed left-0 top-0 h-screen w-16 sidebar-open:w-60 bg-base-200 border-r border-base-300 flex flex-col z-30 transition-[width] duration-200 ease-in-out overflow-hidden">
      <%!-- Logo --%>
      <div class="h-14 flex items-center px-2 shrink-0">
        <.link navigate={~p"/"} class="flex items-center">
          <div class="w-12 h-10 flex items-center justify-center shrink-0">
            <div class="w-8 h-8 rounded-lg bg-primary/10 flex items-center justify-center">
              <span class="text-primary font-bold text-sm">D</span>
            </div>
          </div>
          <span class="text-base font-bold tracking-tight whitespace-nowrap opacity-0 sidebar-open:opacity-100 transition-opacity duration-200">
            Destila
          </span>
        </.link>
      </div>

      <%!-- Navigation --%>
      <nav class="flex-1 flex flex-col gap-0.5 px-2 mt-1">
        <.sidebar_item
          navigate={~p"/crafting"}
          icon="hero-beaker"
          label="Crafting Board"
          active={@page_title == "Crafting Board"}
        />
        <.sidebar_item
          navigate={~p"/projects"}
          icon="hero-folder"
          label="Projects"
          active={@page_title == "Projects"}
        />

        <div class="my-2 mx-1 border-t border-base-300/50" />

        <.sidebar_item
          navigate={~p"/workflows"}
          icon="hero-plus-circle"
          label="New Session"
        />
      </nav>

      <%!-- Bottom --%>
      <div class="shrink-0 border-t border-base-300/50 mx-2 pt-2 pb-3 space-y-1">
        <%!-- Theme toggle --%>
        <button
          phx-click={JS.dispatch("phx:cycle-theme")}
          class="flex items-center h-10 w-full rounded-lg text-base-content/60 hover:text-base-content hover:bg-base-300/50 cursor-pointer transition-colors"
        >
          <div class="w-12 flex items-center justify-center shrink-0 theme-indicator">
            <.icon name="hero-computer-desktop-micro" class="theme-system size-5" />
            <.icon name="hero-sun-micro" class="theme-light size-5" />
            <.icon name="hero-moon-micro" class="theme-dark size-5" />
          </div>
          <span class="text-sm whitespace-nowrap opacity-0 sidebar-open:opacity-100 transition-opacity duration-200 theme-indicator">
            <span class="theme-system">System</span>
            <span class="theme-light">Light</span>
            <span class="theme-dark">Dark</span>
          </span>
        </button>

        <%!-- Sidebar toggle --%>
        <button
          phx-click={JS.dispatch("phx:toggle-sidebar")}
          class="flex items-center justify-center w-full h-9 rounded-lg text-base-content/40 hover:text-base-content hover:bg-base-300/50 cursor-pointer transition-colors"
        >
          <.icon
            name="hero-chevron-right-micro"
            class="size-4 sidebar-open:rotate-180 transition-transform duration-200"
          />
        </button>
      </div>
    </aside>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp sidebar_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center h-10 rounded-lg transition-colors",
        if(@active,
          do: "bg-base-100 text-base-content font-medium shadow-sm",
          else: "text-base-content/60 hover:text-base-content hover:bg-base-300/50"
        )
      ]}
    >
      <div class="w-12 flex items-center justify-center shrink-0">
        <.icon name={@icon} class="size-5" />
      </div>
      <span class="text-sm whitespace-nowrap opacity-0 sidebar-open:opacity-100 transition-opacity duration-200">
        {@label}
      </span>
    </.link>
    """
  end

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        autoclose={false}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        autoclose={false}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
