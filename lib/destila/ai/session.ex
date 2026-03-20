defmodule Destila.AI.Session do
  @moduledoc """
  A GenServer wrapping a ClaudeCode session with an inactivity timeout.

  Sessions auto-terminate after a configurable period of inactivity.
  """

  use GenServer

  @default_timeout_ms :timer.minutes(5)

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
      |> ClaudeCode.Stream.collect()

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

  defp schedule_timeout(timeout_ms) do
    Process.send_after(self(), :inactivity_timeout, timeout_ms)
  end

  defp reset_timer(state) do
    Process.cancel_timer(state.timer_ref)
    timer_ref = schedule_timeout(state.timeout_ms)
    %{state | timer_ref: timer_ref}
  end
end
