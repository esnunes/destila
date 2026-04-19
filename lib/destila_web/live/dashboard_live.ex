defmodule DestilaWeb.DashboardLive do
  @moduledoc """
  Landing page at `/`.

  Renders a banner listing any required external tools missing from the
  user's `PATH` and a grid of CTA cards pointing at the main features.
  Tool detection is delegated to `Destila.Deps` and re-runs on mount and
  on the "Recheck" button click — no caching, no PubSub.
  """

  use DestilaWeb, :live_view

  alias Destila.Deps

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign_tool_status()}
  end

  def handle_event("recheck", _params, socket) do
    {:noreply, assign_tool_status(socket)}
  end

  defp assign_tool_status(socket) do
    tools = Deps.check()
    missing = Enum.reject(tools, & &1.available?)

    socket
    |> assign(:tools, tools)
    |> assign(:missing_tools, missing)
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title}>
      <div class="p-6 lg:p-8 max-w-6xl mx-auto space-y-8">
        <div>
          <h1 class="text-2xl font-bold tracking-tight">Dashboard</h1>
          <p class="text-sm text-base-content/60 mt-1">
            Jump into a feature or check your environment at a glance.
          </p>
        </div>

        <%= if @missing_tools != [] do %>
          <.missing_tools_banner tools={@missing_tools} />
        <% end %>

        <.feature_overview />
      </div>
    </Layouts.app>
    """
  end

  attr :tools, :list, required: true

  defp missing_tools_banner(assigns) do
    ~H"""
    <section
      id="missing-tools-banner"
      class="rounded-lg border border-amber-300 bg-amber-50 text-amber-950 p-5 shadow-sm"
      role="status"
    >
      <div class="flex items-start gap-3">
        <.icon name="hero-exclamation-triangle" class="size-6 text-amber-600 shrink-0 mt-0.5" />
        <div class="flex-1 min-w-0">
          <h2 class="text-base font-semibold">
            Some required tools are missing
          </h2>
          <p class="text-sm text-amber-900/80 mt-1">
            Install the tools below so every Destila feature works end-to-end.
          </p>
        </div>
        <button
          type="button"
          id="recheck-tools"
          phx-click="recheck"
          class="shrink-0 inline-flex items-center gap-1.5 rounded-md border border-amber-400 bg-white/60 hover:bg-white text-amber-900 text-sm font-medium px-3 py-1.5 transition-colors cursor-pointer"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Recheck
        </button>
      </div>

      <ul class="mt-4 space-y-3">
        <li
          :for={tool <- @tools}
          id={"tool-" <> tool.name}
          class="rounded-md border border-amber-200 bg-white/70 p-3"
        >
          <div class="flex items-baseline justify-between gap-2 flex-wrap">
            <span class="font-semibold text-amber-950">{tool.display_name}</span>
            <.link
              href={tool.docs_url}
              target="_blank"
              rel="noopener noreferrer"
              class="text-xs text-amber-800 hover:text-amber-900 underline underline-offset-2"
            >
              Install docs
            </.link>
          </div>
          <p class="text-sm text-amber-900/80 mt-1">{tool.purpose}</p>
          <div class="mt-2 flex items-stretch gap-2">
            <code
              phx-no-curly-interpolation
              class="flex-1 min-w-0 rounded-md bg-amber-950/90 text-amber-50 text-xs font-mono px-3 py-2 overflow-x-auto whitespace-nowrap"
            >
              {tool.install_command}
            </code>
            <button
              type="button"
              id={"copy-" <> tool.name}
              phx-hook=".CopyToClipboard"
              phx-update="ignore"
              data-copy={tool.install_command}
              aria-label={"Copy install command for " <> tool.display_name}
              class="shrink-0 inline-flex items-center gap-1.5 rounded-md border border-amber-300 bg-white/80 hover:bg-white text-amber-900 text-xs font-medium px-2.5 py-1.5 transition-colors cursor-pointer"
            >
              <.icon name="hero-clipboard-document" class="size-4" />
              <span data-copy-label>Copy</span>
            </button>
          </div>
        </li>
      </ul>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
        export default {
          mounted() {
            this._onClick = async () => {
              const text = this.el.dataset.copy
              if (!text || !navigator.clipboard) return
              try {
                await navigator.clipboard.writeText(text)
                const label = this.el.querySelector("[data-copy-label]")
                if (!label) return
                const original = label.textContent
                label.textContent = "Copied"
                clearTimeout(this._copyTimer)
                this._copyTimer = setTimeout(() => {
                  label.textContent = original
                }, 1500)
              } catch (_err) {
                // Clipboard write can fail in insecure contexts; silently no-op.
              }
            }
            this.el.addEventListener("click", this._onClick)
          },
          destroyed() {
            clearTimeout(this._copyTimer)
            if (this._onClick) this.el.removeEventListener("click", this._onClick)
          }
        }
      </script>
    </section>
    """
  end

  defp feature_overview(assigns) do
    ~H"""
    <section id="feature-overview" class="grid grid-cols-1 md:grid-cols-2 gap-4 lg:gap-5">
      <.feature_card
        id="feature-card-crafting"
        title="Crafting Board"
        description="Track workflow sessions across Waiting, Processing, and Done."
        navigate={~p"/crafting"}
        icon="hero-beaker"
      />
      <.feature_card
        id="feature-card-drafts"
        title="Drafts"
        description="Capture loose ideas in a priority-based kanban before launching them."
        navigate={~p"/drafts"}
        icon="hero-document-text"
      />
      <.feature_card
        id="feature-card-new-workflow"
        title="New Workflow"
        description="Kick off a fresh workflow session from a prompt and a project."
        navigate={~p"/workflows"}
        icon="hero-plus-circle"
      />
      <.feature_card
        id="feature-card-projects"
        title="Projects"
        description="Manage the projects Destila runs workflows against."
        navigate={~p"/projects"}
        icon="hero-folder"
      />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :navigate, :string, required: true
  attr :icon, :string, required: true

  defp feature_card(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class={[
        "group relative flex items-start gap-4 p-5",
        "rounded-xl border border-base-300 bg-base-100 shadow-xs",
        "transition-[background-color,border-color,box-shadow] duration-200 ease-out",
        "hover:border-base-content/15 hover:bg-base-200/50 hover:shadow-sm",
        "dark:hover:bg-base-content/[0.03]",
        "focus-visible:outline-none focus-visible:border-primary/40 focus-visible:ring-2 focus-visible:ring-primary/25"
      ]}
    >
      <div class="shrink-0 size-10 rounded-lg bg-primary/10 text-primary flex items-center justify-center transition-colors duration-200 ease-out group-hover:bg-primary/15">
        <.icon name={@icon} class="size-5" />
      </div>
      <div class="flex-1 min-w-0">
        <h3 class="text-[0.9375rem] font-semibold text-base-content tracking-tight leading-snug">
          {@title}
        </h3>
        <p class="mt-1 text-sm leading-relaxed text-base-content/65">{@description}</p>
      </div>
      <.icon
        name="hero-arrow-right"
        class={[
          "size-4 shrink-0 mt-1.5 text-base-content/25",
          "transition-[color,transform] duration-200 ease-out",
          "group-hover:text-base-content/60 group-hover:translate-x-0.5"
        ]}
      />
    </.link>
    """
  end
end
