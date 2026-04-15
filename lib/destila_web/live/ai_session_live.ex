defmodule DestilaWeb.AiSessionLive do
  use DestilaWeb, :live_view

  alias Destila.AI
  alias Destila.Workflows

  @impl true
  def mount(%{"id" => ws_id, "ai_session_id" => ai_session_id}, _session, socket) do
    workflow_session = Workflows.get_workflow_session(ws_id)

    if is_nil(workflow_session) do
      {:ok,
       socket
       |> put_flash(:error, "Session not found")
       |> push_navigate(to: ~p"/crafting")}
    else
      ai_session = AI.get_ai_session(ai_session_id)

      cond do
        is_nil(ai_session) ->
          {:ok,
           socket
           |> put_flash(:error, "AI session not found")
           |> push_navigate(to: ~p"/sessions/#{ws_id}")}

        ai_session.workflow_session_id != workflow_session.id ->
          {:ok,
           socket
           |> put_flash(:error, "AI session not found")
           |> push_navigate(to: ~p"/sessions/#{ws_id}")}

        true ->
          messages = AI.list_messages_for_ai_session(ai_session_id)

          {:ok,
           socket
           |> assign(:workflow_session, workflow_session)
           |> assign(:ai_session, ai_session)
           |> assign(:page_title, "AI Session — #{workflow_session.title}")
           |> stream(:messages, messages)}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title}>
      <div class="flex flex-col h-full bg-base-200">
        <%!-- Header --%>
        <div class="flex items-center gap-3 px-4 py-2.5 border-b border-base-300 bg-base-100 shrink-0">
          <.link
            navigate={~p"/sessions/#{@workflow_session.id}"}
            class="btn btn-ghost btn-sm btn-square"
            id="ai-session-back-btn"
          >
            <.icon name="hero-arrow-left-micro" class="size-4" />
          </.link>
          <div class="flex items-center gap-2 min-w-0">
            <.icon name="hero-cpu-chip-micro" class="size-4 text-base-content/40" />
            <span class="text-sm text-base-content/60 truncate">
              AI Session — {@workflow_session.title}
            </span>
          </div>
        </div>

        <%!-- Content --%>
        <div class="flex-1 overflow-y-auto p-4 space-y-4">
          <%!-- Metadata block --%>
          <div class="bg-base-100 rounded-lg p-4 space-y-2 border border-base-300">
            <h2 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
              Session Details
            </h2>
            <div class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5 text-sm">
              <span class="text-base-content/40">Created</span>
              <span id="ai-session-created-at" class="text-base-content/70 font-mono">
                {Calendar.strftime(@ai_session.inserted_at, "%Y-%m-%d %H:%M:%S UTC")}
              </span>
              <span class="text-base-content/40">Claude Session</span>
              <span id="ai-session-claude-id" class="text-base-content/70 font-mono break-all">
                {@ai_session.claude_session_id || "—"}
              </span>
            </div>
          </div>

          <%!-- Messages --%>
          <div class="space-y-2">
            <h2 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider px-1">
              Messages
            </h2>
            <div id="ai-session-messages" phx-update="stream">
              <div
                :for={{id, msg} <- @streams.messages}
                id={id}
                class="bg-base-100 rounded-lg p-3 border border-base-300"
              >
                <div class="flex items-center gap-2 mb-1.5">
                  <span class={[
                    "text-xs font-medium px-1.5 py-0.5 rounded uppercase tracking-wide",
                    if(msg.role == :user,
                      do: "bg-primary/10 text-primary",
                      else: "bg-base-300 text-base-content/60"
                    )
                  ]}>
                    {msg.role}
                  </span>
                </div>
                <p class="text-sm text-base-content/70 whitespace-pre-wrap break-words leading-relaxed">
                  {msg.content}
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
