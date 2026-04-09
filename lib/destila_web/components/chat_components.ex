defmodule DestilaWeb.ChatComponents do
  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]
  import DestilaWeb.CoreComponents, only: [icon: 1]

  alias Destila.AI.ResponseProcessor
  alias Destila.Workflows

  defp markdown_to_html(text) when is_binary(text) do
    text
    |> Earmark.as_html!(
      code_class_prefix: "language-",
      smartypants: false,
      registered_processors: [
        {"a", &open_links_in_new_tab/1}
      ]
    )
    |> HtmlSanitizeEx.markdown_html()
  end

  defp markdown_to_html(_), do: ""

  defp open_links_in_new_tab({"a", attrs, children, meta}) do
    {"a", [{"target", "_blank"} | attrs], children, meta}
  end

  # --- chat_phase/1: full phase container (replaces AiConversationPhase render) ---

  attr :workflow_session, :map, required: true
  attr :messages, :list, required: true
  attr :phase_number, :integer, required: true
  attr :phase_config, :map, required: true
  attr :streaming_chunks, :any, default: nil
  attr :question_answers, :map, required: true
  attr :metadata, :map, required: true
  attr :current_step, :map, required: true
  attr :phase_status, :atom, default: nil
  attr :exported_metadata, :list, default: []

  def chat_phase(assigns) do
    non_interactive = assigns.phase_config.non_interactive

    assigns =
      assigns
      |> assign(:phase_groups, phase_groups(assigns.messages, assigns.phase_number))
      |> assign(:non_interactive, non_interactive)

    ~H"""
    <div class="flex flex-col h-full">
      <%!-- Scrollable chat area --%>
      <div class="flex-1 min-h-0 overflow-y-auto px-6 py-6" id="chat-messages" phx-hook="ScrollBottom">
        <div class="max-w-2xl mx-auto">
          <%= for {phase, group} <- @phase_groups do %>
            <%= if @workflow_session.total_phases > 1 do %>
              <details
                id={"phase-section-#{phase}"}
                phx-hook=".PhaseToggle"
                class={["phase-section", phase == elem(hd(@phase_groups), 0) && "first-phase"]}
                open={phase >= @phase_number}
              >
                <summary class="flex items-center gap-3 my-6 cursor-pointer group list-none">
                  <div class="flex-1 h-px bg-base-300" />
                  <span class="flex items-center gap-1.5 text-xs font-medium text-base-content/40 uppercase tracking-wide group-hover:text-base-content/60 transition-colors">
                    Phase {phase} — {Workflows.phase_name(@workflow_session.workflow_type, phase)}
                    <.icon name="hero-chevron-down-micro" class="size-3 phase-chevron" />
                  </span>
                  <div class="flex-1 h-px bg-base-300" />
                </summary>
                <.chat_message
                  :for={msg <- group}
                  message={msg}
                  workflow_session={@workflow_session}
                  phase_status={@phase_status}
                  exported_metadata={@exported_metadata}
                />
                <%= if phase == @phase_number && @phase_status == :setup do %>
                  <div class="flex items-center gap-3 text-sm pl-2 mt-2">
                    <span class="loading loading-spinner loading-xs shrink-0" />
                    <span class="text-base-content/60">Preparing workspace...</span>
                  </div>
                <% end %>
                <%= if phase == @phase_number && @phase_status == :processing do %>
                  <%= if @streaming_chunks && @streaming_chunks != [] do %>
                    <.chat_stream_debug chunks={@streaming_chunks} />
                  <% else %>
                    <.chat_typing_indicator />
                  <% end %>
                <% end %>
              </details>
            <% else %>
              <div id={"phase-section-#{phase}"}>
                <.chat_message
                  :for={msg <- group}
                  message={msg}
                  workflow_session={@workflow_session}
                  phase_status={@phase_status}
                  exported_metadata={@exported_metadata}
                />
                <%= if phase == @phase_number && @phase_status == :setup do %>
                  <div class="flex items-center gap-3 text-sm pl-2 mt-2">
                    <span class="loading loading-spinner loading-xs shrink-0" />
                    <span class="text-base-content/60">Preparing workspace...</span>
                  </div>
                <% end %>
                <%= if phase == @phase_number && @phase_status == :processing do %>
                  <%= if @streaming_chunks && @streaming_chunks != [] do %>
                    <.chat_stream_debug chunks={@streaming_chunks} />
                  <% else %>
                    <.chat_typing_indicator />
                  <% end %>
                <% end %>
              </div>
            <% end %>
          <% end %>

          <%!-- Interactive-only: inline structured options --%>
          <div
            :if={
              !@non_interactive &&
                !@current_step.completed &&
                @current_step.input_type in [:single_select, :multi_select]
            }
            class="ml-11 mb-4"
          >
            <p :if={@current_step.question_title} class="text-sm font-medium text-base-content mb-3">
              {@current_step.question_title}
            </p>
            <.chat_input
              input_type={@current_step.input_type}
              options={@current_step.options}
              inline
            />
          </div>

          <%!-- Interactive-only: inline multi-question form --%>
          <div
            :if={
              !@non_interactive &&
                !@current_step.completed &&
                @current_step.input_type == :questions
            }
            class="ml-11 mb-4"
          >
            <.multi_question_input
              questions={@current_step.questions}
              answers={@question_answers}
            />
          </div>
        </div>
      </div>

      <%!-- Non-interactive: retry/cancel controls --%>
      <div
        :if={@non_interactive && !@current_step.completed}
        class="max-w-2xl mx-auto w-full px-6 pb-4"
      >
        <div class="flex items-center justify-center gap-3">
          <button
            :if={@phase_status == :processing}
            phx-click="cancel_phase"
            id="cancel-phase-btn"
            class="btn btn-outline btn-error btn-sm"
          >
            <.icon name="hero-stop-micro" class="size-4" /> Cancel
          </button>
          <button
            :if={@phase_status == :awaiting_input}
            phx-click="retry_phase"
            id="retry-phase-btn"
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-arrow-path-micro" class="size-4" /> Retry
          </button>
        </div>
      </div>

      <%!-- Interactive: text input with inline cancel/retry --%>
      <div
        :if={
          !@non_interactive &&
            !@current_step.completed &&
            @phase_status not in [:awaiting_confirmation]
        }
        class="max-w-2xl mx-auto w-full px-6 pb-4"
      >
        <.text_input
          disabled={@phase_status == :processing}
          show_cancel={@phase_status == :processing}
          show_retry={@phase_status == :awaiting_input}
        />
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".PhaseToggle">
        // Module-level map: element ID → boolean (user's desired open state).
        // Shared across all hook instances since each <details> has a unique id.
        const userOverrides = new Map();

        export default {
          mounted() {
            // Snapshot what the server initially set for this element
            this._serverOpen = this.el.hasAttribute("open");
            this._restoring = false;

            // The native "toggle" event fires when <details> open state changes,
            // whether by user click or programmatic attribute change.
            this.el.addEventListener("toggle", () => {
              // Skip toggles caused by our own restoration in updated()
              if (this._restoring) return;

              const isOpen = this.el.hasAttribute("open");

              if (isOpen !== this._serverOpen) {
                // User toggled away from server default — record override
                userOverrides.set(this.el.id, isOpen);
              } else {
                // User toggled back to match server — clear override
                userOverrides.delete(this.el.id);
              }
            });
          },

          updated() {
            // After LiveView patches the DOM, capture what the server wants.
            // This MUST happen before any restoration so _serverOpen always
            // reflects the server's intent, not our override.
            this._serverOpen = this.el.hasAttribute("open");

            if (!userOverrides.has(this.el.id)) return;

            const desired = userOverrides.get(this.el.id);

            // If the server's new default matches the user's preference
            // (e.g. after phase advance), the override is redundant — clear it
            if (desired === this._serverOpen) {
              userOverrides.delete(this.el.id);
              return;
            }

            // Restore the user's preference, suppressing the toggle event
            this._restoring = true;
            if (desired) {
              this.el.setAttribute("open", "");
            } else {
              this.el.removeAttribute("open");
            }
            // The toggle event fires asynchronously after attribute change.
            // Use requestAnimationFrame to clear the flag after it fires.
            requestAnimationFrame(() => { this._restoring = false; });
          },

          destroyed() {
            userOverrides.delete(this.el.id);
          }
        }
      </script>
    </div>
    """
  end

  defp phase_groups(messages, current_phase) do
    groups =
      messages
      |> Enum.group_by(& &1.phase)
      |> Enum.sort_by(fn {phase, _} -> phase end)

    if Enum.any?(groups, fn {phase, _} -> phase == current_phase end) do
      groups
    else
      groups ++ [{current_phase, []}]
    end
  end

  # --- chat_message ---

  attr :message, :map, required: true
  attr :workflow_session, :map, default: %{}
  attr :phase_status, :atom, default: nil
  attr :exported_metadata, :list, default: []

  def chat_message(assigns) do
    processed = ResponseProcessor.process_message(assigns.message, assigns.workflow_session)

    assigns =
      assigns
      |> assign(:message, processed)
      |> assign(:exports, processed.exports)

    ~H"""
    <%= if @exports == [] do %>
      {render_chat_message(assigns)}
    <% end %>
    <%= for {export, idx} <- Enum.with_index(@exports) do %>
      <%= cond do %>
        <% (export.type || "text") == "markdown" -> %>
          <.markdown_card
            id={"export-md-#{@message.id}-#{idx}"}
            key={export.key}
            content={export.value}
          />
        <% (export.type || "text") == "video_file" -> %>
          <% meta = Enum.find(@exported_metadata, &(&1.key == export.key)) %>
          <%= if meta do %>
            <.video_card
              id={"export-video-#{@message.id}-#{idx}"}
              key={export.key}
              metadata_id={meta.id}
            />
          <% end %>
        <% true -> %>
          <.plain_card
            id={"export-plain-#{@message.id}-#{idx}"}
            key={export.key}
            content={export.value}
          />
      <% end %>
    <% end %>
    """
  end

  defp render_chat_message(%{message: %{message_type: :phase_advance}} = assigns) do
    ws = assigns.workflow_session
    next_phase = (ws.current_phase || 1) + 1

    assigns = assign(assigns, :next_phase, next_phase)

    assigns =
      assign(
        assigns,
        :next_phase_name,
        Workflows.phase_name(ws.workflow_type, next_phase)
      )

    ~H"""
    <div class="flex gap-3 mb-4">
      <div class="w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold flex-shrink-0 bg-primary text-primary-content">
        D
      </div>
      <div class="max-w-[80%]">
        <div class="rounded-2xl px-4 py-3 text-sm bg-base-200 text-base-content prose prose-sm max-w-none">
          {raw(markdown_to_html(@message.content))}
        </div>

        <%= if @phase_status == :awaiting_confirmation do %>
          <div class="flex gap-2 mt-2">
            <button
              phx-click="confirm_advance"
              class="btn btn-primary btn-sm"
            >
              Continue to Phase {@next_phase}
              <span :if={@next_phase_name} class="hidden sm:inline">
                — {@next_phase_name}
              </span>
              <.icon name="hero-arrow-right-micro" class="size-3.5" />
            </button>
            <button
              phx-click="decline_advance"
              class="btn btn-ghost btn-sm"
            >
              I have more to add
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_chat_message(assigns) do
    ~H"""
    <div class={[
      "flex gap-3 mb-4",
      if(@message.role == :user, do: "flex-row-reverse")
    ]}>
      <div class={[
        "w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold flex-shrink-0",
        if(@message.role == :system,
          do: "bg-primary text-primary-content",
          else: "bg-neutral text-neutral-content"
        )
      ]}>
        {if @message.role == :system, do: "D", else: "U"}
      </div>

      <div class={[
        "rounded-2xl px-4 py-3 text-sm",
        if(@message.input_type in [:single_select, :multi_select, :questions],
          do: "flex-1",
          else: "max-w-[80%]"
        ),
        if(@message.role == :system,
          do: "bg-base-200 text-base-content",
          else: "bg-primary text-primary-content"
        )
      ]}>
        <%= if @message.role == :system do %>
          <div class="prose prose-sm max-w-none">
            {raw(markdown_to_html(@message.content))}
          </div>
        <% else %>
          <p class="whitespace-pre-wrap">{@message.content}</p>
        <% end %>

        <%!-- Show selected options for user responses --%>
        <div :if={@message.selected && @message.selected != []} class="mt-2 flex flex-wrap gap-1">
          <span
            :for={opt <- @message.selected}
            class="badge badge-sm badge-outline border-primary-content/30 text-primary-content/80"
          >
            {opt}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # --- Export card components ---

  attr :id, :string, required: true
  attr :key, :string, required: true
  attr :content, :string, required: true

  defp markdown_card(assigns) do
    ~H"""
    <div class="flex gap-3 mb-4">
      <div class="w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold flex-shrink-0 bg-primary text-primary-content">
        D
      </div>
      <div class="max-w-[80%]">
        <div
          id={@id}
          class="rounded-2xl border-2 border-primary/20 bg-base-200 overflow-hidden"
          phx-hook=".MarkdownCard"
          data-content={@content}
        >
          <div class="px-4 py-2 bg-primary/10 border-b border-primary/20 flex items-center justify-between gap-2">
            <span class="text-xs font-medium text-primary uppercase tracking-wide">
              {humanize_key(@key)}
            </span>
            <div class="flex items-center gap-1">
              <div role="tablist" class="flex rounded-lg bg-base-300/50 p-0.5">
                <button
                  role="tab"
                  aria-selected="true"
                  data-view="rendered"
                  class="md-card-tab px-2 py-0.5 text-xs font-medium rounded-md transition-colors bg-base-100 text-base-content shadow-sm"
                >
                  Rendered
                </button>
                <button
                  role="tab"
                  aria-selected="false"
                  data-view="markdown"
                  class="md-card-tab px-2 py-0.5 text-xs font-medium rounded-md transition-colors text-base-content/50 hover:text-base-content"
                >
                  Markdown
                </button>
              </div>
              <button
                class="md-card-copy-btn ml-1 p-1 rounded-md hover:bg-base-300/50 transition-colors"
                aria-label="Copy markdown to clipboard"
              >
                <.icon name="hero-clipboard-document-micro" class="size-4 text-base-content/50" />
              </button>
            </div>
          </div>
          <div data-rendered class="px-4 py-3 text-sm text-base-content prose prose-sm max-w-none">
            {raw(markdown_to_html(@content))}
          </div>
          <div data-markdown class="hidden px-4 py-3">
            <pre class="text-sm font-mono text-base-content whitespace-pre-wrap break-words bg-base-300/30 rounded-lg p-3 overflow-x-auto"><code>{@content}</code></pre>
          </div>
        </div>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".MarkdownCard">
      export default {
        mounted() {
          this.activeView = "rendered"
          this.lastContent = this.el.dataset.content

          this.el.querySelectorAll(".md-card-tab").forEach(tab => {
            tab.addEventListener("click", () => this.switchView(tab.dataset.view))
          })

          this.el.querySelector(".md-card-copy-btn").addEventListener("click", () => this.copyMarkdown())
        },

        updated() {
          const newContent = this.el.dataset.content
          if (newContent !== this.lastContent) {
            this.lastContent = newContent
            this.activeView = "rendered"
          }
          this.applyView()
        },

        switchView(view) {
          this.activeView = view
          this.applyView()
        },

        applyView() {
          const rendered = this.el.querySelector("[data-rendered]")
          const markdown = this.el.querySelector("[data-markdown]")
          const tabs = this.el.querySelectorAll(".md-card-tab")

          if (this.activeView === "markdown") {
            rendered.classList.add("hidden")
            markdown.classList.remove("hidden")
          } else {
            rendered.classList.remove("hidden")
            markdown.classList.add("hidden")
          }

          tabs.forEach(tab => {
            const isActive = tab.dataset.view === this.activeView
            tab.setAttribute("aria-selected", isActive)
            if (isActive) {
              tab.classList.add("bg-base-100", "text-base-content", "shadow-sm")
              tab.classList.remove("text-base-content/50")
            } else {
              tab.classList.remove("bg-base-100", "text-base-content", "shadow-sm")
              tab.classList.add("text-base-content/50")
            }
          })
        },

        async copyMarkdown() {
          const content = this.el.dataset.content
          const btn = this.el.querySelector(".md-card-copy-btn")
          try {
            await navigator.clipboard.writeText(content)
            this.showCopyFeedback(btn, true)
          } catch {
            this.showCopyFeedback(btn, false)
          }
        },

        showCopyFeedback(btn, success) {
          const icon = btn.querySelector("[class*='hero-']")
          const original = icon.className
          if (success) {
            icon.className = icon.className.replace("hero-clipboard-document-micro", "hero-check-micro")
            btn.setAttribute("aria-label", "Copied!")
          } else {
            icon.className = icon.className.replace("hero-clipboard-document-micro", "hero-x-mark-micro")
            btn.setAttribute("aria-label", "Copy failed")
          }
          clearTimeout(this._feedbackTimer)
          this._feedbackTimer = setTimeout(() => {
            icon.className = original
            btn.setAttribute("aria-label", "Copy markdown to clipboard")
          }, 2000)
        }
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :key, :string, required: true
  attr :content, :string, required: true

  defp plain_card(assigns) do
    ~H"""
    <div class="flex gap-3 mb-4">
      <div class="w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold flex-shrink-0 bg-primary text-primary-content">
        D
      </div>
      <div class="max-w-[80%]">
        <div
          id={@id}
          class="rounded-2xl border-2 border-primary/20 bg-base-200 overflow-hidden"
          phx-hook=".PlainCard"
          data-content={@content}
        >
          <div class="px-4 py-2 bg-primary/10 border-b border-primary/20 flex items-center justify-between gap-2">
            <span class="text-xs font-medium text-primary uppercase tracking-wide">
              {humanize_key(@key)}
            </span>
            <button
              class="plain-card-copy-btn p-1 rounded-md hover:bg-base-300/50 transition-colors"
              aria-label="Copy to clipboard"
            >
              <.icon name="hero-clipboard-document-micro" class="size-4 text-base-content/50" />
            </button>
          </div>
          <div class="px-4 py-3 text-sm text-base-content whitespace-pre-wrap break-words">
            {@content}
          </div>
        </div>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PlainCard">
      export default {
        mounted() {
          this.el.querySelector(".plain-card-copy-btn")
            .addEventListener("click", () => this.copyContent())
        },

        async copyContent() {
          const content = this.el.dataset.content
          const btn = this.el.querySelector(".plain-card-copy-btn")
          try {
            await navigator.clipboard.writeText(content)
            this.showCopyFeedback(btn, true)
          } catch {
            this.showCopyFeedback(btn, false)
          }
        },

        showCopyFeedback(btn, success) {
          const icon = btn.querySelector("[class*='hero-']")
          const original = icon.className
          if (success) {
            icon.className = icon.className.replace("hero-clipboard-document-micro", "hero-check-micro")
            btn.setAttribute("aria-label", "Copied!")
          } else {
            icon.className = icon.className.replace("hero-clipboard-document-micro", "hero-x-mark-micro")
            btn.setAttribute("aria-label", "Copy failed")
          }
          clearTimeout(this._feedbackTimer)
          this._feedbackTimer = setTimeout(() => {
            icon.className = original
            btn.setAttribute("aria-label", "Copy to clipboard")
          }, 2000)
        }
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :key, :string, required: true
  attr :metadata_id, :string, required: true

  defp video_card(assigns) do
    ~H"""
    <div class="flex gap-3 mb-4">
      <div class="w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold flex-shrink-0 bg-primary text-primary-content">
        D
      </div>
      <div class="max-w-[80%]">
        <div id={@id} class="rounded-2xl border-2 border-primary/20 bg-base-200 overflow-hidden">
          <div class="px-4 py-2 bg-primary/10 border-b border-primary/20 flex items-center gap-2">
            <.icon name="hero-film-micro" class="size-4 text-primary" />
            <span class="text-xs font-medium text-primary uppercase tracking-wide">
              {humanize_key(@key)}
            </span>
          </div>
          <div class="p-3">
            <video controls preload="metadata" class="w-full rounded-lg">
              <source src={"/media/#{@metadata_id}"} type="video/mp4" />
            </video>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp humanize_key(key) when is_binary(key) do
    key
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # --- Streaming / typing ---

  attr :chunks, :list, required: true

  def chat_stream_debug(assigns) do
    latest = assigns.chunks |> List.last() |> format_chunk()
    assigns = assign(assigns, :latest, latest)

    ~H"""
    <div class="flex gap-3 mb-4">
      <div class="w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold flex-shrink-0 bg-primary text-primary-content">
        D
      </div>
      <div class="rounded-2xl px-4 py-3 bg-base-200 text-base-content max-w-[80%]">
        <div class="font-mono text-xs text-base-content/70 truncate">
          <span class="font-semibold">{@latest.label}</span> {@latest.detail}
        </div>
        <div class="flex items-center gap-1.5 mt-2">
          <span class="w-1.5 h-1.5 rounded-full bg-base-content/30 animate-bounce [animation-delay:0ms]" />
          <span class="w-1.5 h-1.5 rounded-full bg-base-content/30 animate-bounce [animation-delay:150ms]" />
          <span class="w-1.5 h-1.5 rounded-full bg-base-content/30 animate-bounce [animation-delay:300ms]" />
        </div>
      </div>
    </div>
    """
  end

  defp format_chunk(%ClaudeCode.Message.AssistantMessage{message: message}) do
    texts =
      message.content
      |> Enum.filter(&match?(%ClaudeCode.Content.TextBlock{}, &1))
      |> Enum.map(& &1.text)

    tools =
      message.content
      |> Enum.filter(fn
        %ClaudeCode.Content.ToolUseBlock{} -> true
        %ClaudeCode.Content.MCPToolUseBlock{} -> true
        _ -> false
      end)
      |> Enum.map(fn
        %ClaudeCode.Content.ToolUseBlock{name: name} -> name
        %ClaudeCode.Content.MCPToolUseBlock{name: name} -> name
      end)

    detail =
      cond do
        texts != [] -> Enum.join(texts, "")
        tools != [] -> "tools: " <> Enum.join(tools, ", ")
        true -> inspect(message.content, limit: 100)
      end

    %{label: "[assistant]", detail: truncate(detail, 100)}
  end

  defp format_chunk(%ClaudeCode.Message.ResultMessage{} = msg) do
    %{
      label: "[result]",
      detail:
        truncate(
          "subtype=#{msg.subtype} cost=$#{Float.round(msg.total_cost_usd || 0.0, 4)} turns=#{msg.num_turns}",
          100
        )
    }
  end

  defp format_chunk(%ClaudeCode.Message.UserMessage{message: message}) do
    content =
      case message.content do
        text when is_binary(text) -> text
        other -> inspect(other, limit: 100)
      end

    %{label: "[user]", detail: truncate(content, 100)}
  end

  defp format_chunk(%ClaudeCode.Message.ToolProgressMessage{} = msg) do
    %{
      label: "[tool_progress]",
      detail: truncate("#{msg.tool_name} (#{msg.elapsed_time_seconds || 0}s)", 100)
    }
  end

  defp format_chunk(%ClaudeCode.Message.PartialAssistantMessage{event: event}) do
    detail =
      case event do
        %{type: :content_block_delta, delta: delta} ->
          "delta: #{inspect(delta, limit: 100)}"

        %{type: type} ->
          "#{type}"

        other ->
          inspect(other, limit: 100)
      end

    %{label: "[stream_event]", detail: truncate(detail, 100)}
  end

  defp format_chunk(other) do
    %{
      label: "[#{struct_type_name(other)}]",
      detail: truncate(inspect(other, limit: 100), 100)
    }
  end

  defp truncate(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> " …"
    else
      text
    end
  end

  defp struct_type_name(%{__struct__: mod}) do
    mod |> Module.split() |> List.last() |> Macro.underscore()
  end

  defp struct_type_name(_), do: "unknown"

  def chat_typing_indicator(assigns) do
    ~H"""
    <div class="flex gap-3 mb-4">
      <div class="w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold flex-shrink-0 bg-primary text-primary-content">
        D
      </div>
      <div class="rounded-2xl px-4 py-3 bg-base-200">
        <div class="flex items-center gap-1">
          <span class="w-2 h-2 rounded-full bg-base-content/30 animate-bounce [animation-delay:0ms]" />
          <span class="w-2 h-2 rounded-full bg-base-content/30 animate-bounce [animation-delay:150ms]" />
          <span class="w-2 h-2 rounded-full bg-base-content/30 animate-bounce [animation-delay:300ms]" />
        </div>
      </div>
    </div>
    """
  end

  # --- Input components (target removed — events bubble to LiveView) ---

  attr :input_type, :atom, required: true
  attr :options, :list, default: nil
  attr :disabled, :boolean, default: false
  attr :inline, :boolean, default: false

  def chat_input(assigns) do
    ~H"""
    <div class={[
      "p-4",
      if(@inline, do: "bg-transparent", else: "border-t border-base-300 bg-base-100")
    ]}>
      <.text_input :if={@input_type == :text} disabled={@disabled} />
      <.single_select_input
        :if={@input_type == :single_select}
        options={@options || []}
      />
      <.multi_select_input
        :if={@input_type == :multi_select}
        options={@options || []}
      />
    </div>
    """
  end

  attr :disabled, :boolean, default: false
  attr :show_cancel, :boolean, default: false
  attr :show_retry, :boolean, default: false

  def text_input(assigns) do
    ~H"""
    <form phx-submit="send_text" class="flex gap-2">
      <input
        type="text"
        name="content"
        placeholder={if @disabled, do: "AI is thinking...", else: "Type your response..."}
        class={[
          "input input-bordered flex-1",
          @disabled && "opacity-50"
        ]}
        autofocus={!@disabled}
        autocomplete="off"
        disabled={@disabled}
      />
      <button type="submit" class="btn btn-primary" disabled={@disabled}>
        Send
      </button>
      <button
        :if={@show_cancel}
        type="button"
        phx-click="cancel_phase"
        id="cancel-phase-btn"
        class="btn btn-outline btn-error"
      >
        <.icon name="hero-stop-micro" class="size-4" /> Cancel
      </button>
      <button
        :if={@show_retry}
        type="button"
        phx-click="retry_phase"
        id="retry-phase-btn"
        class="btn btn-outline"
      >
        <.icon name="hero-arrow-path-micro" class="size-4" /> Retry
      </button>
    </form>
    <p :if={!@disabled} class="text-xs text-base-content/30 mt-2">Press Enter to send</p>
    """
  end

  attr :options, :list, required: true

  def single_select_input(assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">Pick one</p>
      <div class="grid gap-2">
        <button
          :for={opt <- @options}
          phx-click="select_single"
          phx-value-label={opt.label}
          class="card bg-base-100 border border-base-300 hover:border-primary hover:shadow-sm transition-all cursor-pointer text-left"
        >
          <div class="card-body p-3 flex-row items-center gap-3">
            <div class="w-4 h-4 rounded-full border-2 border-base-300 flex-shrink-0" />
            <div>
              <span class="text-sm font-medium">{opt.label}</span>
              <p :if={opt[:description]} class="text-xs text-base-content/50">{opt.description}</p>
            </div>
          </div>
        </button>
      </div>
      <div class="divider text-xs text-base-content/30">or</div>
      <form phx-submit="send_text" class="flex gap-2">
        <input
          type="text"
          name="content"
          placeholder="Other (type your own)..."
          class="input input-bordered input-sm flex-1"
          autocomplete="off"
        />
        <button type="submit" class="btn btn-sm btn-ghost">Send</button>
      </form>
    </div>
    """
  end

  attr :options, :list, required: true

  def multi_select_input(assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">
        Select all that apply
      </p>
      <form phx-submit="select_multi" class="space-y-2">
        <label
          :for={opt <- @options}
          class="card bg-base-100 border border-base-300 hover:border-primary transition-all cursor-pointer"
        >
          <div class="card-body p-3 flex-row items-center gap-3">
            <input
              type="checkbox"
              name="selected[]"
              value={opt.label}
              class="checkbox checkbox-sm checkbox-primary"
            />
            <div>
              <span class="text-sm font-medium">{opt.label}</span>
              <p :if={opt[:description]} class="text-xs text-base-content/50">{opt.description}</p>
            </div>
          </div>
        </label>

        <div class="divider text-xs text-base-content/30">or</div>
        <div class="flex gap-2">
          <input
            type="text"
            name="other"
            placeholder="Other (type your own)..."
            class="input input-bordered input-sm flex-1"
            autocomplete="off"
          />
        </div>

        <button type="submit" class="btn btn-primary w-full mt-2">
          Confirm Selection
        </button>
      </form>
    </div>
    """
  end

  attr :questions, :list, required: true
  attr :answers, :map, required: true

  def multi_question_input(assigns) do
    total = length(assigns.questions)
    answered = map_size(assigns.answers)
    all_answered = answered == total

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:answered_count, answered)
      |> assign(:all_answered, all_answered)

    ~H"""
    <div class="space-y-4 py-2">
      <div :for={{q, idx} <- Enum.with_index(@questions)} class="space-y-2">
        <%!-- Answered question: show locked-in state --%>
        <%= if Map.has_key?(@answers, idx) do %>
          <div class="rounded-lg border border-base-300/50 bg-base-200/30 p-3 space-y-1">
            <div class="flex items-center gap-2">
              <.icon name="hero-check-circle-solid" class="size-4 text-success flex-shrink-0" />
              <p class="text-xs font-medium text-base-content/50 uppercase tracking-wide">
                {q.title}
              </p>
            </div>
            <p class="text-sm text-base-content/70 pl-6">{@answers[idx]}</p>
          </div>
        <% else %>
          <%!-- Current unanswered question: show interactive --%>
          <%= if map_size(@answers) == idx do %>
            <div class="space-y-2">
              <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">
                {q.title}
                <span class="text-base-content/30 ml-1">({idx + 1}/{@total})</span>
              </p>
              <p class="text-sm font-medium text-base-content">{q.question}</p>

              <%= if q.input_type == :single_select do %>
                <div class="grid gap-2">
                  <button
                    :for={opt <- q.options}
                    phx-click="answer_question"
                    phx-value-index={idx}
                    phx-value-answer={opt.label}
                    class="card bg-base-100 border border-base-300 hover:border-primary hover:shadow-sm transition-all cursor-pointer text-left"
                  >
                    <div class="card-body p-3 flex-row items-center gap-3">
                      <div class="w-4 h-4 rounded-full border-2 border-base-300 flex-shrink-0" />
                      <div>
                        <span class="text-sm font-medium">{opt.label}</span>
                        <p :if={opt[:description]} class="text-xs text-base-content/50">
                          {opt.description}
                        </p>
                      </div>
                    </div>
                  </button>
                </div>
                <form phx-submit="answer_question" class="flex gap-2">
                  <input type="hidden" name="index" value={idx} />
                  <input
                    type="text"
                    name="answer"
                    placeholder="Other (type your own)..."
                    class="input input-bordered input-sm flex-1"
                    autocomplete="off"
                  />
                  <button type="submit" class="btn btn-sm btn-ghost">Send</button>
                </form>
              <% else %>
                <form phx-submit="confirm_multi_answer" class="space-y-2">
                  <input type="hidden" name="index" value={idx} />
                  <div class="grid gap-2">
                    <label
                      :for={opt <- q.options}
                      class="card bg-base-100 border border-base-300 hover:border-primary transition-all cursor-pointer"
                    >
                      <div class="card-body p-3 flex-row items-center gap-3">
                        <input
                          type="checkbox"
                          name="selected[]"
                          value={opt.label}
                          class="checkbox checkbox-sm checkbox-primary"
                        />
                        <div>
                          <span class="text-sm font-medium">{opt.label}</span>
                          <p :if={opt[:description]} class="text-xs text-base-content/50">
                            {opt.description}
                          </p>
                        </div>
                      </div>
                    </label>
                  </div>
                  <input
                    type="text"
                    name="other"
                    placeholder="Other (type your own)..."
                    class="input input-bordered input-sm w-full"
                    autocomplete="off"
                  />
                  <button type="submit" class="btn btn-primary btn-sm w-full">
                    Confirm
                  </button>
                </form>
              <% end %>
            </div>
          <% else %>
            <%!-- Future unanswered question: show dimmed preview --%>
            <div class="rounded-lg border border-base-300/30 bg-base-200/10 p-3 opacity-40">
              <p class="text-xs font-medium text-base-content/40 uppercase tracking-wide">
                {q.title}
                <span class="text-base-content/20 ml-1">({idx + 1}/{@total})</span>
              </p>
              <p class="text-sm text-base-content/40 mt-1">{q.question}</p>
            </div>
          <% end %>
        <% end %>
      </div>

      <%!-- Submit all when done --%>
      <%= if @all_answered do %>
        <button phx-click="submit_all_answers" class="btn btn-primary w-full">
          Submit All Answers
        </button>
      <% end %>
    </div>
    """
  end
end
