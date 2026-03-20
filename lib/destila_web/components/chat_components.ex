defmodule DestilaWeb.ChatComponents do
  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]
  import DestilaWeb.CoreComponents, only: [icon: 1]

  defp markdown_to_html(text) when is_binary(text) do
    text
    |> Earmark.as_html!(code_class_prefix: "language-", smartypants: false)
  end

  defp markdown_to_html(_), do: ""

  attr :message, :map, required: true
  attr :prompt, :map, default: %{}

  def chat_message(%{message: %{message_type: :phase_divider}} = assigns) do
    ~H"""
    <div class="flex items-center gap-3 my-6">
      <div class="flex-1 h-px bg-base-300" />
      <span class="text-xs font-medium text-base-content/40 uppercase tracking-wide">
        {@message.content}
      </span>
      <div class="flex-1 h-px bg-base-300" />
    </div>
    """
  end

  def chat_message(%{message: %{message_type: :phase_advance}} = assigns) do
    next_phase = (assigns.prompt[:steps_completed] || 1) + 1

    assigns = assign(assigns, :next_phase, next_phase)

    assigns =
      assign(assigns, :next_phase_name, Destila.Workflows.ChoreTaskPhases.phase_name(next_phase))

    ~H"""
    <div class="flex gap-3 mb-4">
      <div class="w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold flex-shrink-0 bg-primary text-primary-content">
        D
      </div>
      <div class="max-w-[80%]">
        <div class="rounded-2xl px-4 py-3 text-sm bg-base-200 text-base-content prose prose-sm max-w-none">
          {raw(markdown_to_html(@message.content))}
        </div>

        <%= if @prompt[:phase_status] == :advance_suggested do %>
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

  def chat_message(%{message: %{message_type: :generated_prompt}} = assigns) do
    ~H"""
    <div class="flex gap-3 mb-4">
      <div class="w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold flex-shrink-0 bg-primary text-primary-content">
        D
      </div>
      <div class="max-w-[80%]">
        <div class="rounded-2xl border-2 border-primary/20 bg-base-200 overflow-hidden">
          <div class="px-4 py-2 bg-primary/10 border-b border-primary/20">
            <span class="text-xs font-medium text-primary uppercase tracking-wide">
              Implementation Prompt
            </span>
          </div>
          <div class="px-4 py-3 text-sm text-base-content prose prose-sm max-w-none">
            {raw(markdown_to_html(@message.content))}
          </div>
        </div>
      </div>
    </div>
    """
  end

  def chat_message(assigns) do
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
        if(@message[:input_type] in [:single_select, :multi_select, :questions],
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
      <.single_select_input :if={@input_type == :single_select} options={@options || []} />
      <.multi_select_input :if={@input_type == :multi_select} options={@options || []} />
      <.file_upload_input :if={@input_type == :file_upload} />
    </div>
    """
  end

  attr :disabled, :boolean, default: false

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

  def file_upload_input(assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">
        Upload a file
      </p>
      <button
        phx-click="mock_upload"
        class="border-2 border-dashed border-base-300 rounded-xl p-8 w-full hover:border-primary hover:bg-base-200/50 transition-all cursor-pointer flex flex-col items-center gap-2"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          class="size-8 text-base-content/30"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="1.5"
            d="M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5m-13.5-9L12 3m0 0l4.5 4.5M12 3v13.5"
          />
        </svg>
        <span class="text-sm text-base-content/50">Click to upload (mocked)</span>
      </button>
      <div class="divider text-xs text-base-content/30">or</div>
      <form phx-submit="send_text" class="flex gap-2">
        <input
          type="text"
          name="content"
          placeholder="Skip with a text response..."
          class="input input-bordered input-sm flex-1"
          autocomplete="off"
        />
        <button type="submit" class="btn btn-sm btn-ghost">Send</button>
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
