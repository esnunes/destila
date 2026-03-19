defmodule DestilaWeb.ChatComponents do
  use Phoenix.Component

  attr :message, :map, required: true

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
        "max-w-[80%] rounded-2xl px-4 py-3 text-sm",
        if(@message.role == :system,
          do: "bg-base-200 text-base-content",
          else: "bg-primary text-primary-content"
        )
      ]}>
        <p class="whitespace-pre-wrap">{@message.content}</p>

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

  attr :input_type, :atom, required: true
  attr :options, :list, default: nil

  def chat_input(assigns) do
    ~H"""
    <div class="border-t border-base-300 bg-base-100 p-4">
      <.text_input :if={@input_type == :text} />
      <.single_select_input :if={@input_type == :single_select} options={@options || []} />
      <.multi_select_input :if={@input_type == :multi_select} options={@options || []} />
      <.file_upload_input :if={@input_type == :file_upload} />
    </div>
    """
  end

  def text_input(assigns) do
    ~H"""
    <form phx-submit="send_text" class="flex gap-2">
      <input
        type="text"
        name="content"
        placeholder="Type your response..."
        class="input input-bordered flex-1"
        autofocus
        autocomplete="off"
      />
      <button type="submit" class="btn btn-primary">
        Send
      </button>
    </form>
    <p class="text-xs text-base-content/30 mt-2">Press Enter to send</p>
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
end
