defmodule Destila.AI.Session do
  @moduledoc """
  A GenServer wrapping a ClaudeCode session with an inactivity timeout.

  Sessions auto-terminate after a configurable period of inactivity.
  """

  use GenServer

  @default_timeout_ms :timer.minutes(5)
  @default_allowed_tools [
    "Read",
    "Grep",
    "Glob",
    "Bash(git log:*)",
    "Bash(git show:*)",
    "mcp__destila__ask_user_question"
  ]

  # Client API

  @doc """
  Starts a new AI session under the `Destila.AI.SessionSupervisor`.

  ## Options

    * `:timeout_ms` — inactivity timeout in milliseconds (default: 5 minutes)
    * all other options are forwarded to `ClaudeCode.start_link/1`
  """
  def start_link(opts \\ []) do
    {gen_opts, session_opts} = Keyword.split(opts, [:name])

    DynamicSupervisor.start_child(
      Destila.AI.SessionSupervisor,
      {__MODULE__, Keyword.merge(session_opts, gen_opts)}
    )
  end

  def child_spec(opts) do
    {gen_opts, _session_opts} = Keyword.split(opts, [:name])

    %{
      id: gen_opts[:name] || __MODULE__,
      start: {__MODULE__, :start_link_internal, [opts]},
      restart: :temporary
    }
  end

  @doc false
  def start_link_internal(opts) do
    {gen_opts, session_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, session_opts, gen_opts)
  end

  @doc """
  Sends a prompt to the session and returns the result.

  Returns `{:ok, result}` or `{:error, result}` where result includes:
  - `:result` — final text from the AI
  - `:is_error` — whether an error occurred
  - `:mcp_tool_uses` — list of MCP tool use blocks (e.g., ask_user_question)

  Resets the inactivity timer on each call.
  """
  def query(session, prompt, opts \\ []) do
    GenServer.call(session, {:query, prompt, opts}, :infinity)
  end

  @doc """
  Returns the underlying ClaudeCode session ID for resumption.
  """
  def session_id(session) do
    GenServer.call(session, :session_id)
  end

  @doc """
  Stops the session and its underlying ClaudeCode process.
  """
  def stop(session) do
    GenServer.stop(session, :normal)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    {timeout_ms, claude_opts} = Keyword.pop(opts, :timeout_ms, @default_timeout_ms)
    claude_opts = Keyword.put_new(claude_opts, :allowed_tools, @default_allowed_tools)

    claude_opts =
      Keyword.put_new(claude_opts, :mcp_servers, %{"destila" => Destila.AI.Tools})

    case ClaudeCode.start_link(claude_opts) do
      {:ok, claude_session} ->
        timer_ref = schedule_timeout(timeout_ms)

        {:ok,
         %{
           claude_session: claude_session,
           timeout_ms: timeout_ms,
           timer_ref: timer_ref
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:query, prompt, opts}, _from, state) do
    state = reset_timer(state)

    result =
      state.claude_session
      |> ClaudeCode.stream(prompt, opts)
      |> collect_with_mcp()

    reply =
      if result.is_error do
        {:error, result}
      else
        {:ok, result}
      end

    {:reply, reply, state}
  end

  def handle_call(:session_id, _from, state) do
    id = ClaudeCode.Session.session_id(state.claude_session)
    {:reply, id, state}
  end

  @impl true
  def handle_info(:inactivity_timeout, state) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    ClaudeCode.stop(state.claude_session)
    :ok
  end

  # Collects stream results like ClaudeCode.Stream.collect/1 but also captures
  # MCPToolUseBlock entries which collect/1 ignores.
  defp collect_with_mcp(stream) do
    initial = %{
      text: [],
      mcp_tool_uses: [],
      result: nil,
      is_error: false,
      session_id: nil
    }

    acc =
      Enum.reduce(stream, initial, fn
        %ClaudeCode.Message.AssistantMessage{message: message}, acc ->
          {texts, mcp_tools} = extract_content(message.content)

          %{
            acc
            | text: texts ++ acc.text,
              mcp_tool_uses: mcp_tools ++ acc.mcp_tool_uses
          }

        %ClaudeCode.Message.ResultMessage{} = msg, acc ->
          %{
            acc
            | result: msg.result,
              is_error: msg.is_error,
              session_id: msg.session_id
          }

        _, acc ->
          acc
      end)

    %{
      result: acc.result,
      text: acc.text |> Enum.reverse() |> Enum.join(),
      is_error: acc.is_error,
      session_id: acc.session_id,
      mcp_tool_uses: Enum.reverse(acc.mcp_tool_uses)
    }
  end

  defp extract_content(content) do
    Enum.reduce(content, {[], []}, fn
      %ClaudeCode.Content.TextBlock{text: text}, {texts, tools} ->
        {[text | texts], tools}

      %ClaudeCode.Content.MCPToolUseBlock{} = tool, {texts, tools} ->
        {texts, [tool | tools]}

      %ClaudeCode.Content.ToolUseBlock{name: "mcp__" <> _} = tool, {texts, tools} ->
        {texts, [tool | tools]}

      _, acc ->
        acc
    end)
  end

  defp schedule_timeout(timeout_ms) do
    Process.send_after(self(), :inactivity_timeout, timeout_ms)
  end

  defp reset_timer(state) do
    Process.cancel_timer(state.timer_ref)
    timer_ref = schedule_timeout(state.timeout_ms)
    %{state | timer_ref: timer_ref}
  end
end
