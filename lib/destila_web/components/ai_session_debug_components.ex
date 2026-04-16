defmodule DestilaWeb.AiSessionDebugComponents do
  @moduledoc """
  Function components that render a Claude Code session history
  (a list of `%ClaudeCode.History.SessionMessage{}` structs) for the
  AI Session Debug Detail page.

  Each content block type gets its own branch in `content_block/1`;
  unknown shapes fall through to a generic `inspect/2` block so new
  block types from future ClaudeCode releases don't crash the page.
  """

  use Phoenix.Component

  import DestilaWeb.CoreComponents, only: [icon: 1]

  alias ClaudeCode.Content.{
    CompactionBlock,
    ContainerUploadBlock,
    DocumentBlock,
    ImageBlock,
    MCPToolResultBlock,
    MCPToolUseBlock,
    RedactedThinkingBlock,
    ServerToolResultBlock,
    ServerToolUseBlock,
    TextBlock,
    ThinkingBlock,
    ToolResultBlock,
    ToolUseBlock
  }

  alias ClaudeCode.History.SessionMessage

  attr :messages, :list, required: true
  attr :tool_index, :map, default: %{}

  def session_history(assigns) do
    ~H"""
    <div id="session-history" class="flex flex-col gap-4">
      <%= for {msg, idx} <- Enum.with_index(@messages) do %>
        <.session_message msg={msg} idx={idx} tool_index={@tool_index} />
      <% end %>
    </div>
    """
  end

  attr :msg, :any, required: true
  attr :idx, :integer, required: true
  attr :tool_index, :map, required: true

  defp session_message(%{msg: %SessionMessage{type: :user} = msg} = assigns) do
    assigns = assign(assigns, :content, extract_content(msg.message))

    ~H"""
    <div
      id={"message-#{@idx}"}
      data-message-role="user"
      data-message-uuid={@msg.uuid}
      class="rounded-lg border border-primary/20 bg-primary/5 px-4 py-3"
    >
      <.role_header role="user" />
      <.content_list content={@content} tool_index={@tool_index} idx={@idx} />
    </div>
    """
  end

  defp session_message(%{msg: %SessionMessage{type: :assistant} = msg} = assigns) do
    assigns = assign(assigns, :content, extract_content(msg.message))

    ~H"""
    <div
      id={"message-#{@idx}"}
      data-message-role="assistant"
      data-message-uuid={@msg.uuid}
      class="rounded-lg border border-base-300 bg-base-100 px-4 py-3"
    >
      <.role_header role="assistant" />
      <.content_list content={@content} tool_index={@tool_index} idx={@idx} />
    </div>
    """
  end

  defp session_message(assigns) do
    ~H"""
    <div
      id={"message-#{@idx}"}
      data-message-role="unknown"
      class="rounded-lg border border-warning/30 bg-warning/5 px-4 py-3"
    >
      <p class="text-xs text-base-content/50 mb-2">Unrecognized message</p>
      <pre class="text-xs text-base-content/70 whitespace-pre-wrap break-words">{inspect(@msg, pretty: true, limit: :infinity)}</pre>
    </div>
    """
  end

  attr :role, :string, required: true

  defp role_header(assigns) do
    ~H"""
    <div class="flex items-center gap-2 mb-2">
      <span class={[
        "text-[10px] font-semibold uppercase tracking-wider",
        role_color(@role)
      ]}>
        {@role}
      </span>
    </div>
    """
  end

  defp role_color("user"), do: "text-primary"
  defp role_color("assistant"), do: "text-base-content/60"
  defp role_color(_), do: "text-base-content/40"

  attr :content, :any, required: true
  attr :tool_index, :map, required: true
  attr :idx, :integer, required: true

  defp content_list(%{content: content} = assigns) when is_binary(content) do
    ~H"""
    <p class="text-sm text-base-content/80 whitespace-pre-wrap break-words">{@content}</p>
    """
  end

  defp content_list(%{content: content} = assigns) when is_list(content) do
    assigns = assign(assigns, :blocks, content)

    ~H"""
    <div class="flex flex-col gap-2">
      <%= for {block, i} <- Enum.with_index(@blocks) do %>
        <.content_block block={block} tool_index={@tool_index} block_id={"block-#{@idx}-#{i}"} />
      <% end %>
    </div>
    """
  end

  defp content_list(assigns) do
    ~H"""
    <pre class="text-xs text-base-content/60 whitespace-pre-wrap break-words">{inspect(@content, pretty: true, limit: :infinity)}</pre>
    """
  end

  attr :block, :any, required: true
  attr :tool_index, :map, required: true
  attr :block_id, :string, required: true

  defp content_block(%{block: %TextBlock{}} = assigns) do
    ~H"""
    <div id={@block_id} data-block-type="text">
      <p class="text-sm text-base-content/80 whitespace-pre-wrap break-words">{@block.text}</p>
    </div>
    """
  end

  defp content_block(%{block: %ThinkingBlock{}} = assigns) do
    ~H"""
    <details
      id={@block_id}
      data-block-type="thinking"
      class="rounded-md border border-base-300/60 bg-base-200/40"
    >
      <summary class="cursor-pointer px-3 py-2 text-xs text-base-content/60 select-none flex items-center gap-2">
        <.icon name="hero-sparkles-micro" class="size-3 text-base-content/40" />
        <span>Thinking (click to expand)</span>
      </summary>
      <pre class="px-3 pb-3 pt-1 text-xs text-base-content/70 whitespace-pre-wrap break-words">{@block.thinking}</pre>
    </details>
    """
  end

  defp content_block(%{block: %RedactedThinkingBlock{}} = assigns) do
    assigns =
      assign(
        assigns,
        :byte_size,
        if(is_binary(assigns.block.data), do: byte_size(assigns.block.data), else: 0)
      )

    ~H"""
    <div
      id={@block_id}
      data-block-type="redacted_thinking"
      class="rounded-md border border-base-300/60 bg-base-200/40 px-3 py-2"
    >
      <p class="text-xs text-base-content/50 italic">[Redacted thinking — {@byte_size} bytes]</p>
    </div>
    """
  end

  defp content_block(%{block: %ToolUseBlock{}} = assigns) do
    assigns = assign(assigns, :pretty_input, pretty_json(assigns.block.input))

    ~H"""
    <div
      id={@block_id}
      data-block-type="tool_use"
      data-tool-use-id={@block.id}
      class="rounded-md border border-info/30 bg-info/5"
    >
      <div class="px-3 py-2 border-b border-info/20 flex items-center gap-2">
        <.icon name="hero-wrench-screwdriver-micro" class="size-3 text-info/70" />
        <span class="text-xs font-semibold text-info/80">{@block.name}</span>
        <span class="text-[10px] text-base-content/40 font-mono">{@block.id}</span>
      </div>
      <pre class="px-3 py-2 text-xs text-base-content/70 whitespace-pre-wrap break-words">{@pretty_input}</pre>
    </div>
    """
  end

  defp content_block(%{block: %ToolResultBlock{} = block} = assigns) do
    tool_use = Map.get(assigns.tool_index, block.tool_use_id)
    tool_name = tool_use && Map.get(tool_use, :name)

    assigns =
      assigns
      |> assign(:tool_name, tool_name)
      |> assign(:rendered_content, render_tool_result_content(block.content))
      |> assign(:is_error?, block.is_error == true)

    ~H"""
    <div
      id={@block_id}
      data-block-type="tool_result"
      data-tool-use-ref={@block.tool_use_id}
      data-tool-name={@tool_name}
      class={[
        "rounded-md border",
        if(@is_error?,
          do: "border-error/40 bg-error/5",
          else: "border-base-300/60 bg-base-200/40"
        )
      ]}
    >
      <div class={[
        "px-3 py-2 border-b flex items-center gap-2",
        if(@is_error?, do: "border-error/30", else: "border-base-300/40")
      ]}>
        <.icon
          name={
            if(@is_error?, do: "hero-exclamation-triangle-micro", else: "hero-arrow-uturn-left-micro")
          }
          class={[
            "size-3",
            if(@is_error?, do: "text-error/70", else: "text-base-content/40")
          ]}
        />
        <span class="text-xs font-semibold text-base-content/70">
          Result <span :if={@tool_name}>from {@tool_name}</span>
        </span>
        <span :if={@is_error?} class="text-[10px] font-semibold uppercase text-error">
          error
        </span>
      </div>
      <pre class={[
        "px-3 py-2 text-xs whitespace-pre-wrap break-words",
        if(@is_error?, do: "text-error/80", else: "text-base-content/70")
      ]}>{@rendered_content}</pre>
    </div>
    """
  end

  defp content_block(%{block: %ServerToolUseBlock{}} = assigns) do
    assigns = assign(assigns, :pretty_input, pretty_json(assigns.block.input))

    ~H"""
    <div
      id={@block_id}
      data-block-type="server_tool_use"
      data-tool-use-id={@block.id}
      class="rounded-md border border-accent/30 bg-accent/5"
    >
      <div class="px-3 py-2 border-b border-accent/20 flex items-center gap-2">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-accent">
          server tool
        </span>
        <span class="text-xs font-semibold text-base-content/80">{@block.name}</span>
        <span class="text-[10px] text-base-content/40 font-mono">{@block.id}</span>
      </div>
      <pre class="px-3 py-2 text-xs text-base-content/70 whitespace-pre-wrap break-words">{@pretty_input}</pre>
    </div>
    """
  end

  defp content_block(%{block: %ServerToolResultBlock{} = block} = assigns) do
    assigns =
      assigns
      |> assign(:rendered_content, render_tool_result_content(block.content))
      |> assign(:result_type, block.type)

    ~H"""
    <div
      id={@block_id}
      data-block-type="server_tool_result"
      data-tool-use-ref={@block.tool_use_id}
      class="rounded-md border border-accent/20 bg-accent/5"
    >
      <div class="px-3 py-2 border-b border-accent/20 flex items-center gap-2">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-accent">
          server tool result
        </span>
        <span class="text-xs text-base-content/60">{@result_type}</span>
      </div>
      <pre class="px-3 py-2 text-xs text-base-content/70 whitespace-pre-wrap break-words">{@rendered_content}</pre>
    </div>
    """
  end

  defp content_block(%{block: %MCPToolUseBlock{}} = assigns) do
    assigns = assign(assigns, :pretty_input, pretty_json(assigns.block.input))

    ~H"""
    <div
      id={@block_id}
      data-block-type="mcp_tool_use"
      data-tool-use-id={@block.id}
      class="rounded-md border border-secondary/30 bg-secondary/5"
    >
      <div class="px-3 py-2 border-b border-secondary/20 flex items-center gap-2">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-secondary">
          mcp: {@block.server_name}
        </span>
        <span class="text-xs font-semibold text-base-content/80">{@block.name}</span>
        <span class="text-[10px] text-base-content/40 font-mono">{@block.id}</span>
      </div>
      <pre class="px-3 py-2 text-xs text-base-content/70 whitespace-pre-wrap break-words">{@pretty_input}</pre>
    </div>
    """
  end

  defp content_block(%{block: %MCPToolResultBlock{} = block} = assigns) do
    assigns =
      assigns
      |> assign(:rendered_content, render_tool_result_content(block.content))
      |> assign(:is_error?, block.is_error == true)

    ~H"""
    <div
      id={@block_id}
      data-block-type="mcp_tool_result"
      data-tool-use-ref={@block.tool_use_id}
      class={[
        "rounded-md border",
        if(@is_error?,
          do: "border-error/40 bg-error/5",
          else: "border-secondary/20 bg-secondary/5"
        )
      ]}
    >
      <div class="px-3 py-2 border-b border-secondary/20 flex items-center gap-2">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-secondary">
          mcp result
        </span>
        <span :if={@is_error?} class="text-[10px] font-semibold uppercase text-error">
          error
        </span>
      </div>
      <pre class={[
        "px-3 py-2 text-xs whitespace-pre-wrap break-words",
        if(@is_error?, do: "text-error/80", else: "text-base-content/70")
      ]}>{@rendered_content}</pre>
    </div>
    """
  end

  defp content_block(%{block: %ImageBlock{source: %{type: :url, url: url}}} = assigns) do
    assigns = assign(assigns, :url, url)

    ~H"""
    <div id={@block_id} data-block-type="image" data-image-kind="url">
      <img src={@url} alt="image" class="max-w-full rounded-md border border-base-300/60" />
    </div>
    """
  end

  defp content_block(%{block: %ImageBlock{source: %{type: :base64, data: data}}} = assigns) do
    kb = byte_size(data || "") |> div(1024)
    assigns = assign(assigns, :kb, kb)

    ~H"""
    <div
      id={@block_id}
      data-block-type="image"
      data-image-kind="base64"
      class="rounded-md border border-base-300/60 bg-base-200/40 px-3 py-2 flex items-center gap-2"
    >
      <.icon name="hero-photo-micro" class="size-3 text-base-content/40" />
      <span class="text-xs text-base-content/60">Image — base64, {@kb} KB</span>
    </div>
    """
  end

  defp content_block(%{block: %ImageBlock{}} = assigns) do
    ~H"""
    <div
      id={@block_id}
      data-block-type="image"
      class="rounded-md border border-base-300/60 bg-base-200/40 px-3 py-2 flex items-center gap-2"
    >
      <.icon name="hero-photo-micro" class="size-3 text-base-content/40" />
      <span class="text-xs text-base-content/60">Image</span>
    </div>
    """
  end

  defp content_block(%{block: %DocumentBlock{} = block} = assigns) do
    assigns =
      assigns
      |> assign(:title, block.title || "Document")
      |> assign(:context, block.context)

    ~H"""
    <div
      id={@block_id}
      data-block-type="document"
      class="rounded-md border border-base-300/60 bg-base-200/40 px-3 py-2"
    >
      <div class="flex items-center gap-2">
        <.icon name="hero-document-micro" class="size-3 text-base-content/40" />
        <span class="text-xs font-semibold text-base-content/70">{@title}</span>
      </div>
      <p :if={@context} class="text-xs text-base-content/50 mt-1">{@context}</p>
    </div>
    """
  end

  defp content_block(%{block: %ContainerUploadBlock{} = block} = assigns) do
    assigns = assign(assigns, :file_id, block.file_id)

    ~H"""
    <div
      id={@block_id}
      data-block-type="container_upload"
      class="rounded-md border border-base-300/60 bg-base-200/40 px-3 py-2 flex items-center gap-2"
    >
      <.icon name="hero-arrow-up-tray-micro" class="size-3 text-base-content/40" />
      <span class="text-xs text-base-content/60">Uploaded file: {@file_id}</span>
    </div>
    """
  end

  defp content_block(%{block: %CompactionBlock{} = block} = assigns) do
    assigns = assign(assigns, :content, block.content)

    ~H"""
    <div
      id={@block_id}
      data-block-type="compaction"
      class="flex flex-col items-center gap-2 py-3 border-y border-base-300/60"
    >
      <div class="flex items-center gap-2 text-xs font-semibold uppercase tracking-wider text-base-content/50">
        <.icon name="hero-minus-micro" class="size-3" />
        <span>Conversation compacted</span>
        <.icon name="hero-minus-micro" class="size-3" />
      </div>
      <details :if={@content} class="w-full">
        <summary class="text-xs text-base-content/50 cursor-pointer select-none text-center">
          Show compaction summary
        </summary>
        <pre class="mt-2 text-xs text-base-content/60 whitespace-pre-wrap break-words">{@content}</pre>
      </details>
    </div>
    """
  end

  defp content_block(assigns) do
    ~H"""
    <div
      id={@block_id}
      data-block-type="unknown"
      class="rounded-md border border-warning/30 bg-warning/5 px-3 py-2"
    >
      <p class="text-[10px] font-semibold uppercase tracking-wider text-warning mb-1">
        Unknown block
      </p>
      <pre class="text-xs text-base-content/70 whitespace-pre-wrap break-words">{inspect(@block, pretty: true, limit: :infinity)}</pre>
    </div>
    """
  end

  defp extract_content(%{content: content}), do: content
  defp extract_content(%{"content" => content}), do: content
  defp extract_content(_), do: []

  defp render_tool_result_content(content) when is_binary(content), do: content

  defp render_tool_result_content(content) when is_list(content) do
    content
    |> Enum.map(&render_tool_result_item/1)
    |> Enum.join("\n\n")
  end

  defp render_tool_result_content(content), do: inspect(content, pretty: true, limit: :infinity)

  defp render_tool_result_item(%TextBlock{text: text}), do: text

  defp render_tool_result_item(%ImageBlock{source: %{type: :url, url: url}}),
    do: "[image: #{url}]"

  defp render_tool_result_item(%ImageBlock{source: %{type: :base64}}),
    do: "[image: base64]"

  defp render_tool_result_item(%{"type" => "text", "text" => text}) when is_binary(text),
    do: text

  defp render_tool_result_item(other), do: inspect(other, pretty: true, limit: :infinity)

  defp pretty_json(value) do
    Jason.encode!(value, pretty: true)
  rescue
    _ -> inspect(value, pretty: true, limit: :infinity)
  end
end
