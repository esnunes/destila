defmodule Destila.AI.ClaudeSession do
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
    "WebFetch",
    "Skill",
    "Bash(git log:*)",
    "Bash(git show:*)",
    "mcp__destila__ask_user_question",
    "mcp__destila__session"
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
  Gets or creates an AI session for a workflow session.

  If a session already exists for this workflow_session_id (registered in the Registry),
  returns it. Otherwise starts a new one. This ensures multiple tabs/LiveViews
  for the same workflow session share a single AI session.

  ## Options

  Same as `start_link/1`.
  """
  def for_workflow_session(workflow_session_id, opts \\ []) do
    name = {:via, Registry, {Destila.AI.SessionRegistry, workflow_session_id}}

    case GenServer.whereis(name) do
      nil ->
        opts = Keyword.put(opts, :workflow_session_id, workflow_session_id)

        case start_link(Keyword.put(opts, :name, name)) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            # Race condition: another process started it first
            {:ok, pid}

          error ->
            error
        end

      pid ->
        {:ok, pid}
    end
  end

  @doc """
  Sends a prompt to the session and returns the result.

  Broadcasts each raw stream chunk to the given PubSub topic.
  Requires `stream_topic` in opts.

  Returns `{:ok, result}` or `{:error, result}` where result includes:
  - `:result` — final text from the AI
  - `:is_error` — whether an error occurred
  - `:mcp_tool_uses` — list of MCP tool use blocks (e.g., ask_user_question)

  Resets the inactivity timer after each call completes.
  """
  def query_streaming(session, prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :timer.minutes(15))
    GenServer.call(session, {:query_streaming, prompt, opts}, timeout)
  end

  @doc """
  Stops the session and its underlying ClaudeCode process.
  """
  def stop(session) do
    GenServer.stop(session, :normal)
  end

  @doc """
  Stops the AI session for a workflow session, if one is running.
  """
  def stop_for_workflow_session(workflow_session_id) do
    name = {:via, Registry, {Destila.AI.SessionRegistry, workflow_session_id}}

    case GenServer.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 500)
        catch
          :exit, _ ->
            # Forcefully kill if graceful stop times out (e.g., blocked mid-stream).
            # Safe: linked ClaudeCode process dies too.
            Process.exit(pid, :kill)
            :ok
        end
    end
  end

  @doc """
  Builds ClaudeCode session options for a workflow session and phase.

  Resolves the session strategy from the workflow module, adds `:resume`
  and `:cwd` from the AI session record, and merges any phase-provided options.

  Additional base options (e.g. `timeout_ms`) can be passed and will be included.
  """
  def session_opts_for_workflow(workflow_session, phase, base_opts \\ []) do
    phase_def = Enum.at(Destila.Workflows.phases(workflow_session.workflow_type), phase - 1)

    strategy_opts =
      case phase_def do
        %Destila.Workflows.Phase{session_strategy: {_action, opts}} -> opts
        _ -> []
      end

    ai_session = Destila.AI.get_ai_session_for_workflow(workflow_session.id)

    opts = base_opts

    opts =
      if ai_session && ai_session.claude_session_id do
        Keyword.put(opts, :resume, ai_session.claude_session_id)
      else
        opts
      end

    opts =
      if ai_session && ai_session.worktree_path do
        Keyword.put(opts, :cwd, ai_session.worktree_path)
      else
        opts
      end

    # Forward allowed_tools from phase definition if present
    opts =
      case phase_def do
        %Destila.Workflows.Phase{allowed_tools: tools} when tools != [] ->
          Keyword.put(opts, :allowed_tools, tools)

        _ ->
          opts
      end

    merge_phase_opts(opts, strategy_opts)
  end

  @doc """
  Merges phase-provided ClaudeCode options with base session options.
  MCP servers are map-merged; all other options use standard keyword merge.
  """
  def merge_phase_opts(base_opts, phase_opts) do
    {phase_mcp, phase_rest} = Keyword.pop(phase_opts, :mcp_servers, %{})
    {base_mcp, base_rest} = Keyword.pop(base_opts, :mcp_servers, %{})

    merged = Keyword.merge(base_rest, phase_rest)

    merged_mcp = Map.merge(base_mcp, phase_mcp)

    if merged_mcp == %{} do
      merged
    else
      Keyword.put(merged, :mcp_servers, merged_mcp)
    end
  end

  # Server callbacks

  @impl true
  def init(opts) do
    {timeout_ms, claude_opts} = Keyword.pop(opts, :timeout_ms, @default_timeout_ms)
    {workflow_session_id, claude_opts} = Keyword.pop(claude_opts, :workflow_session_id)
    claude_opts = Keyword.put_new(claude_opts, :allowed_tools, @default_allowed_tools)

    claude_opts =
      Keyword.put_new(claude_opts, :mcp_servers, %{"destila" => Destila.AI.Tools})

    claude_opts = Keyword.put_new(claude_opts, :setting_sources, ["user", "project"])

    # Register marketplaces and install/enable plugins before starting the session.
    # Treat "already" errors as success since these operations aren't fully idempotent.
    with :ok <-
           plugin_cmd(ClaudeCode.Plugin.Marketplace, :add, [
             "EveryInc/compound-engineering-plugin"
           ]),
         :ok <- plugin_cmd(ClaudeCode.Plugin.Marketplace, :add, ["pbakaus/impeccable"]),
         :ok <-
           plugin_cmd(ClaudeCode.Plugin, :install, [
             "compound-engineering@compound-engineering-plugin"
           ]),
         :ok <-
           plugin_cmd(ClaudeCode.Plugin, :enable, [
             "compound-engineering@compound-engineering-plugin"
           ]),
         :ok <- plugin_cmd(ClaudeCode.Plugin, :install, ["impeccable@impeccable"]),
         :ok <- plugin_cmd(ClaudeCode.Plugin, :enable, ["impeccable@impeccable"]),
         {:ok, installed} <- ClaudeCode.Plugin.list() do
      # Pass enabled plugin install_paths so they are loaded into the session.
      plugin_paths =
        installed
        |> Enum.filter(&(&1.enabled && &1.install_path))
        |> Enum.map(& &1.install_path)

      claude_opts = Keyword.put(claude_opts, :plugins, plugin_paths)

      case ClaudeCode.start_link(claude_opts) do
        {:ok, claude_session} ->
          timer_ref = schedule_timeout(timeout_ms)

          if workflow_session_id do
            Phoenix.PubSub.broadcast(
              Destila.PubSub,
              Destila.PubSubHelper.claude_session_topic(),
              {:claude_session_started, workflow_session_id}
            )
          end

          {:ok,
           %{
             claude_session: claude_session,
             timeout_ms: timeout_ms,
             timer_ref: timer_ref,
             workflow_session_id: workflow_session_id
           }}

        {:error, reason} ->
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, {:plugin_setup_failed, reason}}
    end
  end

  @impl true
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

  @impl true
  def handle_info(:inactivity_timeout, state) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    ClaudeCode.stop(state.claude_session)
    :ok
  end

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
        Phoenix.PubSub.broadcast(Destila.PubSub, topic, {:ai_stream_chunk, item})

        case item do
          %ClaudeCode.Message.AssistantMessage{message: message} ->
            {texts, mcp_tools} = extract_content(message.content)

            %{
              acc
              | text: texts ++ acc.text,
                mcp_tool_uses: mcp_tools ++ acc.mcp_tool_uses
            }

          %ClaudeCode.Message.ResultMessage{} = msg ->
            %{
              acc
              | result: msg.result,
                is_error: msg.is_error,
                session_id: msg.session_id
            }

          _ ->
            acc
        end
      end)

    %{
      result: acc.result,
      text: acc.text |> Enum.reverse() |> Enum.join("\n\n"),
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

    # Flush any queued timeout message that fired during a long handle_call
    receive do
      :inactivity_timeout -> :ok
    after
      0 -> :ok
    end

    timer_ref = schedule_timeout(state.timeout_ms)
    %{state | timer_ref: timer_ref}
  end

  defp plugin_cmd(module, function, args) do
    case apply(module, function, args) do
      {:ok, _} ->
        :ok

      {:error, msg} when is_binary(msg) ->
        if String.contains?(msg, "already") do
          :ok
        else
          {:error, msg}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
