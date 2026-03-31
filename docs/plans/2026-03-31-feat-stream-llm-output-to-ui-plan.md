# Stream LLM Output to UI in Real-Time — Implementation Plan

## Overview

Replace the current "typing indicator until full response" behavior with real-time streaming of AI output to the chat UI. Stream chunks are broadcast as they arrive from `ClaudeCode.stream()`, rendered incrementally in the LiveComponent, and replaced seamlessly by the final DB-persisted message when the stream completes.

## Architecture

```
ClaudeCode.stream()
    │ (each chunk)
    ├──▶ PubSub broadcast to "ai_stream:<ws_id>" ──▶ WorkflowRunnerLive
    │                                                      │
    │                                                      ▼
    │                                              AiConversationPhase
    │                                              (ephemeral assign: streaming_content)
    │
    ▼ (Enum.reduce — unchanged collection)
AiQueryWorker collects full result
    │
    ▼
Engine.phase_update() → DB insert → {:workflow_session_updated, ws}
                                          │
                                          ▼
                                   WorkflowRunnerLive clears ephemeral assign
                                   AiConversationPhase.update/2 re-queries messages
```

## Files to Change

| File | Change |
|------|--------|
| `lib/destila/ai/claude_session.ex` | New `query_streaming/3` that broadcasts chunks while collecting |
| `lib/destila/workers/ai_query_worker.ex` | Call `query_streaming` instead of `query`, pass `ws_id` |
| `lib/destila/pub_sub_helper.ex` | Add `ai_stream_topic/1` helper |
| `lib/destila_web/live/workflow_runner_live.ex` | Subscribe to `ai_stream:<ws_id>`, forward chunks to child, clear on final message |
| `lib/destila_web/live/phases/ai_conversation_phase.ex` | Accept streaming assign, render ephemeral content |
| `lib/destila_web/components/chat_components.ex` | New `chat_streaming_message/1` component |
| `test/destila/ai/session_test.exs` | Tests for streaming broadcast behavior |
| `test/destila_web/live/chore_task_workflow_live_test.exs` | Integration test for streaming UI |

## Implementation Steps

### Step 1: Add `ai_stream_topic/1` to PubSubHelper

**File:** `lib/destila/pub_sub_helper.ex`

Add a function to generate the dedicated PubSub topic for a workflow session's AI stream:

```elixir
def ai_stream_topic(workflow_session_id) do
  "ai_stream:#{workflow_session_id}"
end
```

This keeps the topic convention in one place and avoids string interpolation scattered across modules.

### Step 2: Add `query_streaming/3` to ClaudeSession

**File:** `lib/destila/ai/claude_session.ex`

Add a new GenServer call that iterates the `ClaudeCode.stream()` enumerable while broadcasting each raw chunk to a PubSub topic, then returns the collected result (identical to `query/3`'s return).

**Client API:**

```elixir
def query_streaming(session, prompt, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, :timer.minutes(15))
  GenServer.call(session, {:query_streaming, prompt, opts}, timeout)
end
```

**Server callback — new `handle_call` clause:**

```elixir
def handle_call({:query_streaming, prompt, opts}, _from, state) do
  topic = Keyword.fetch!(opts, :stream_topic)

  result =
    state.claude_session
    |> ClaudeCode.stream(prompt, Keyword.delete(opts, :stream_topic))
    |> collect_with_mcp_and_broadcast(topic)

  state = reset_timer(state)

  reply =
    if result.is_error do
      {:error, result}
    else
      {:ok, result}
    end

  {:reply, reply, state}
end
```

**New `collect_with_mcp_and_broadcast/2`:**

This function wraps the existing `collect_with_mcp/1` logic but broadcasts each raw stream item before accumulating it. The broadcast message format is `{:ai_stream_chunk, chunk}` where `chunk` is the raw ClaudeCode message struct.

```elixir
defp collect_with_mcp_and_broadcast(stream, topic) do
  initial = %{
    text: [],
    mcp_tool_uses: [],
    result: nil,
    is_error: false,
    session_id: nil
  }

  acc =
    Enum.reduce(stream, initial, fn item, acc ->
      # Broadcast raw chunk
      Phoenix.PubSub.broadcast(Destila.PubSub, topic, {:ai_stream_chunk, item})

      # Accumulate as before
      case item do
        %ClaudeCode.Message.AssistantMessage{message: message} ->
          {texts, mcp_tools} = extract_content(message.content)
          %{acc | text: texts ++ acc.text, mcp_tool_uses: mcp_tools ++ acc.mcp_tool_uses}

        %ClaudeCode.Message.ResultMessage{} = msg ->
          %{acc | result: msg.result, is_error: msg.is_error, session_id: msg.session_id}

        _ ->
          acc
      end
    end)

  %{
    result: acc.result,
    text: acc.text |> Enum.reverse() |> Enum.join(),
    is_error: acc.is_error,
    session_id: acc.session_id,
    mcp_tool_uses: Enum.reverse(acc.mcp_tool_uses)
  }
end
```

**Design decisions:**
- Broadcasts raw ClaudeCode structs rather than pre-processing them. This gives the UI maximum flexibility to render different chunk types (text deltas, tool use blocks, results).
- The existing `query/3` and `collect_with_mcp/1` are left unchanged — no regressions for any code paths that don't need streaming.
- The `stream_topic` option is passed through `opts` and removed before forwarding to `ClaudeCode.stream()`.

### Step 3: Update AiQueryWorker to use streaming

**File:** `lib/destila/workers/ai_query_worker.ex`

Change the worker to call `query_streaming/3` instead of `query/3`, passing the stream topic.

```elixir
def perform(%Oban.Job{args: %{"workflow_session_id" => workflow_session_id, "phase" => phase, "query" => query}}) do
  ws = Workflows.get_workflow_session!(workflow_session_id)
  ai_session_record = AI.get_ai_session_for_workflow(workflow_session_id)

  unless ai_session_record do
    raise "No AI session record found for workflow session #{workflow_session_id}"
  end

  session_opts = AI.ClaudeSession.session_opts_for_workflow(ws, phase)

  case AI.ClaudeSession.for_workflow_session(workflow_session_id, session_opts) do
    {:ok, session} ->
      stream_topic = Destila.PubSubHelper.ai_stream_topic(workflow_session_id)

      case AI.ClaudeSession.query_streaming(session, query, stream_topic: stream_topic) do
        {:ok, result} ->
          Destila.Executions.Engine.phase_update(ws.id, phase, %{ai_result: result})
          :ok

        {:error, reason} ->
          Destila.Executions.Engine.phase_update(ws.id, phase, %{ai_error: reason})
          :ok
      end

    {:error, reason} ->
      Destila.Executions.Engine.phase_update(ws.id, phase, %{ai_error: reason})
      {:error, reason}
  end
end
```

The only change is calling `query_streaming` with `stream_topic` instead of `query`. Everything downstream (Engine.phase_update, DB persistence) is untouched.

### Step 4: Subscribe to stream topic in WorkflowRunnerLive

**File:** `lib/destila_web/live/workflow_runner_live.ex`

**In `mount_session/2`** — subscribe to the AI stream topic alongside the existing `store:updates` subscription:

```elixir
if connected?(socket) do
  Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
  Phoenix.PubSub.subscribe(Destila.PubSub, Destila.PubSubHelper.ai_stream_topic(id))
end
```

Add a `streaming_content` assign initialized to `nil`:

```elixir
|> assign(:streaming_content, nil)
```

**Also in `mount_workflow/2`** — add the same assign so that pre-session phase rendering doesn't crash on a missing assign when `render_phase` passes `streaming_content` to the phase component:

```elixir
|> assign(:streaming_content, nil)
```

**New `handle_info` clause for stream chunks** (must be placed BEFORE the catch-all `handle_info(_msg, socket)` at line 279):

```elixir
def handle_info({:ai_stream_chunk, chunk}, socket) do
  streaming = socket.assigns[:streaming_content] || ""

  new_text =
    case chunk do
      %ClaudeCode.Message.AssistantMessage{message: message} ->
        message.content
        |> Enum.filter(&match?(%ClaudeCode.Content.TextBlock{}, &1))
        |> Enum.map(& &1.text)
        |> Enum.join()

      _ ->
        ""
    end

  {:noreply, assign(socket, :streaming_content, streaming <> new_text)}
end
```

**Clear streaming content when `:workflow_session_updated` arrives** (the existing handler):

In the existing `handle_info({:workflow_session_updated, updated_ws}, socket)` handler, add `assign(:streaming_content, nil)` when the workflow session's `phase_status` transitions away from `:processing`:

```elixir
def handle_info({:workflow_session_updated, updated_ws}, socket) do
  if socket.assigns[:workflow_session] &&
       updated_ws.id == socket.assigns.workflow_session.id do
    ws = Workflows.get_workflow_session!(updated_ws.id)

    {:noreply,
     socket
     |> assign(:workflow_session, ws)
     |> assign(:current_phase, ws.current_phase)
     |> assign(:page_title, ws.title)
     |> assign(:streaming_content, if(ws.phase_status == :processing, do: socket.assigns[:streaming_content], else: nil))}
  else
    {:noreply, socket}
  end
end
```

**Pass `streaming_content` to the phase component** in `render_phase/1`:

```elixir
<.live_component
  module={@phase_module}
  id={"phase-#{@current_phase}"}
  workflow_session={@workflow_session}
  workflow_type={@workflow_type}
  metadata={@metadata}
  opts={@phase_opts}
  phase_number={@current_phase}
  streaming_content={@streaming_content}
/>
```

### Step 5: Render streaming content in AiConversationPhase

**File:** `lib/destila_web/live/phases/ai_conversation_phase.ex`

**In `update/2`** — accept the new `streaming_content` assign:

```elixir
|> assign(:streaming_content, assigns[:streaming_content])
```

**In `render/3`** — replace the typing indicator with streamed content when available:

```elixir
<%!-- Streaming / typing indicator --%>
<%= if phase == @phase_number && @workflow_session.phase_status == :processing do %>
  <%= if @streaming_content && @streaming_content != "" do %>
    <.chat_streaming_message content={@streaming_content} />
  <% else %>
    <.chat_typing_indicator />
  <% end %>
<% end %>
```

This replaces the existing single line:
```elixir
<.chat_typing_indicator :if={
  phase == @phase_number && @workflow_session.phase_status == :processing
} />
```

### Step 6: Add `chat_streaming_message/1` component

**File:** `lib/destila_web/components/chat_components.ex`

New component that renders the in-progress streamed AI message with the same visual style as a system message:

```elixir
attr :content, :string, required: true

def chat_streaming_message(assigns) do
  ~H"""
  <div class="flex gap-3 mb-4">
    <div class="w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold flex-shrink-0 bg-primary text-primary-content">
      D
    </div>
    <div class="rounded-2xl px-4 py-3 text-sm bg-base-200 text-base-content max-w-[80%]">
      <div class="prose prose-sm max-w-none">
        {raw(markdown_to_html(@content))}
      </div>
    </div>
  </div>
  """
end
```

This looks identical to a regular system message, ensuring the transition from streamed → persisted is seamless with no visual flicker.

### Step 7: Handle edge cases

#### 7a. Cancel during streaming — requires code change

**Problem:** The current `stop_for_workflow_session/1` calls `GenServer.stop(pid, :normal)`, which sends a system message to the GenServer. However, OTP processes system messages _between_ callbacks, not during them. Since `handle_call({:query_streaming, ...})` blocks on `Enum.reduce(stream, ...)` for the duration of the AI response, `GenServer.stop` will **block indefinitely** until the stream finishes. This means pressing Cancel would hang until the AI completes its full response — directly violating the requirement.

**Fix — File:** `lib/destila/ai/claude_session.ex`

Change `stop_for_workflow_session/1` to use `Process.exit/2` with a short grace period:

```elixir
def stop_for_workflow_session(workflow_session_id) do
  name = {:via, Registry, {Destila.AI.SessionRegistry, workflow_session_id}}

  case GenServer.whereis(name) do
    nil ->
      :ok

    pid ->
      # Try graceful stop with a short timeout. If the GenServer is blocked
      # mid-stream (inside handle_call), this will timeout quickly.
      try do
        GenServer.stop(pid, :normal, 500)
      catch
        :exit, _ ->
          # Forcefully kill the process if graceful stop times out.
          # This is safe: the Oban worker's GenServer.call will receive
          # an {:EXIT, pid, :killed} and the job will fail (max_attempts: 1).
          # The underlying ClaudeCode process is also killed since it's
          # linked to the GenServer.
          Process.exit(pid, :kill)
      end
  end
end
```

**Why this is safe:**
- `ClaudeCode.start_link` creates a linked process — when the GenServer is killed, the underlying Claude process dies too (no leak).
- The Oban worker's `GenServer.call` receives an exit signal, causing the job to fail. Since `max_attempts: 1`, it won't retry.
- The `cancel_phase` handler in AiConversationPhase already updates `phase_status` to `:conversing` after calling `stop_for_workflow_session`, so the UI transitions correctly regardless.
- The `terminate/2` callback won't run on `:kill`, but that's OK since the linked ClaudeCode process dies automatically.

**Note:** The existing `stop/1` function (used elsewhere for graceful shutdown) is left unchanged. Only `stop_for_workflow_session` gets the timeout+kill fallback since it's the one called during cancel.

#### 7b. Error during streaming

If `ClaudeCode.stream()` errors mid-stream, the GenServer's `handle_call` will return `{:error, result}`. The worker calls `Engine.phase_update(ws.id, phase, %{ai_error: reason})`, which updates `phase_status` away from `:processing`. The WorkflowRunnerLive handler clears `streaming_content`.

#### 7c. Navigate away and back

When the user navigates away, the LiveView process dies and the PubSub subscription is lost. When they return:
- `mount_session` initializes `streaming_content` to `nil`
- If streaming is still in progress, `phase_status` is `:processing`, so the typing indicator shows
- When streaming completes, the normal `:workflow_session_updated` flow renders the final message

This matches the specified behavior: typing indicator on reconnect, then final message.

#### 7d. Non-interactive phases

Non-interactive phases use the same `AiConversationPhase` component. The streaming content flows identically through the same PubSub → LiveView → LiveComponent path. No special handling needed.

### Step 8: Tests

#### 8a. Unit test — ClaudeSession streaming broadcasts

**File:** `test/destila/ai/session_test.exs`

```elixir
describe "query_streaming/3" do
  test "broadcasts stream chunks to the given topic" do
    topic = PubSubHelper.ai_stream_topic("test-ws-id")
    Phoenix.PubSub.subscribe(Destila.PubSub, topic)

    ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
      [
        ClaudeCode.Test.text("Hello "),
        ClaudeCode.Test.text("world"),
        ClaudeCode.Test.result("Hello world")
      ]
    end)

    {:ok, session} = AI.ClaudeSession.start_link()
    {:ok, result} = AI.ClaudeSession.query_streaming(session, "test", stream_topic: topic)

    # Verify chunks were broadcast
    assert_received {:ai_stream_chunk, %ClaudeCode.Message.AssistantMessage{}}
    assert_received {:ai_stream_chunk, %ClaudeCode.Message.AssistantMessage{}}
    assert_received {:ai_stream_chunk, %ClaudeCode.Message.ResultMessage{}}

    # Verify final result is still collected correctly
    assert result.text == "Hello world"
  end
end
```

#### 8b. Integration test — LiveView receives and renders streamed content

**File:** `test/destila_web/live/chore_task_workflow_live_test.exs`

Add a test in the existing test file that verifies:

1. When a stream chunk is broadcast, the LiveView renders the streamed text (replacing the typing indicator)
2. When the final message is saved, the streaming content is cleared and the persisted message appears

```elixir
describe "AI streaming" do
  test "streams AI response chunks to the chat UI", %{conn: conn} do
    # Setup: create session in processing state at an AI conversation phase
    ws = create_session_in_phase(3, phase_status: :processing)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    # Initially shows typing indicator
    assert has_element?(view, "[class*='animate-bounce']")

    # Simulate a stream chunk broadcast
    topic = Destila.PubSubHelper.ai_stream_topic(ws.id)
    chunk = %ClaudeCode.Message.AssistantMessage{
      message: %{content: [%ClaudeCode.Content.TextBlock{text: "Streaming text"}]}
    }
    Phoenix.PubSub.broadcast(Destila.PubSub, topic, {:ai_stream_chunk, chunk})

    # Verify streaming content replaces typing indicator
    assert render(view) =~ "Streaming text"
    refute has_element?(view, "[class*='animate-bounce']")

    # Simulate final message saved + workflow session updated
    # (mimics what happens when AiQueryWorker completes)
    {:ok, ws} = Workflows.update_workflow_session(ws, %{phase_status: :conversing})

    # Verify streaming content is cleared
    refute render(view) =~ "Streaming text"
  end
end
```

#### 8c. Unit test — cancel kills the session mid-stream

**File:** `test/destila/ai/session_test.exs`

```elixir
describe "stop_for_workflow_session/1 during streaming" do
  test "kills the session even when blocked mid-stream" do
    # Stub with a slow stream that blocks
    ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
      # Simulate a long-running stream
      Process.sleep(5_000)
      [ClaudeCode.Test.result("never reached")]
    end)

    ws_id = "test-cancel-ws"
    {:ok, session} = AI.ClaudeSession.for_workflow_session(ws_id)

    # Start streaming in a separate process
    task = Task.async(fn ->
      AI.ClaudeSession.query_streaming(session, "test", stream_topic: "ai_stream:#{ws_id}")
    end)

    # Give the stream time to start
    Process.sleep(50)

    # Cancel should return quickly (not block for 5s)
    {elapsed_us, :ok} = :timer.tc(fn -> AI.ClaudeSession.stop_for_workflow_session(ws_id) end)
    assert elapsed_us < 2_000_000  # Less than 2 seconds

    # The task should exit with an error
    assert {:exit, _} = catch_exit(Task.await(task, 1_000))
  end
end
```

## Implementation Order

1. **Step 1** — `PubSubHelper.ai_stream_topic/1` (trivial, no deps)
2. **Step 2** — `ClaudeSession.query_streaming/3` (core streaming logic)
3. **Step 3** — `AiQueryWorker` uses `query_streaming` (wires up the broadcast)
4. **Step 6** — `chat_streaming_message/1` component (UI building block)
5. **Step 5** — `AiConversationPhase` renders streaming content
6. **Step 4** — `WorkflowRunnerLive` subscribes and forwards
7. **Step 8** — Tests

Steps 1-3 can be implemented and tested together as the backend streaming pipeline. Steps 4-6 form the frontend rendering pipeline. Step 7 (edge cases) is handled naturally by the existing architecture with no additional code.

## Risk Assessment

**Low risk:**
- Existing `query/3` path is untouched — no regression for non-streaming callers
- PubSub broadcasts are fire-and-forget — if no subscriber exists, chunks are silently dropped
- The ephemeral assign pattern (streaming_content) is entirely client-side state, no DB schema changes

**Medium risk:**
- Markdown rendering of partial content: incomplete markdown (e.g., unclosed code blocks) may render oddly mid-stream. Earmark handles this gracefully in practice, but edge cases exist. Could add a trailing newline or use a simpler renderer for streaming content if needed.
- High-frequency PubSub messages: each text delta triggers a LiveView re-render. For very fast streams, this could cause performance issues. If needed in the future, a `Process.send_after`-based throttle (e.g., 50ms) can be added, but the spec explicitly says "no throttling" so this is deferred.
