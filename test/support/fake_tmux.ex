defmodule Destila.Terminal.FakeTmux do
  @moduledoc """
  Test double for `Destila.Terminal.Tmux`. Each call is forwarded as a
  `{:tmux, op, args}` message to the pid registered via `register/0`, so
  tests can assert on the sequence of calls without running tmux itself.

  Tests opt in by setting `Application.put_env(:destila, :tmux,
  Destila.Terminal.FakeTmux)`.
  """

  @key :destila_fake_tmux_pid

  def register, do: :persistent_term.put(@key, self())

  def register(pid) when is_pid(pid), do: :persistent_term.put(@key, pid)

  defp send_call(op, args) do
    case :persistent_term.get(@key, nil) do
      nil -> :ok
      pid -> send(pid, {:tmux, op, args})
    end
  end

  def session_name(ws) do
    send_call(:session_name, [ws])
    ws.title |> String.replace(~r/[^0-9a-zA-Z_-]/, "-")
  end

  def ensure_session(name, cwd) do
    send_call(:ensure_session, [name, cwd])
    :ok
  end

  def new_window(target, opts \\ []) do
    send_call(:new_window, [target, opts])
    {"", 0}
  end

  def send_keys(target, command) do
    case :persistent_term.get({@key, :send_keys_fun}, nil) do
      nil ->
        send_call(:send_keys, [target, command])
        {"", 0}

      fun ->
        send_call(:send_keys, [target, command])
        fun.(target, command)
    end
  end

  def kill_window(target) do
    send_call(:kill_window, [target])
    {"", 0}
  end

  def window_exists?(target) do
    send_call(:window_exists?, [target])
    true
  end

  @doc """
  Installs a custom send_keys function (e.g. to raise). Pass `nil` to clear.
  """
  def stub_send_keys(nil), do: :persistent_term.erase({@key, :send_keys_fun})

  def stub_send_keys(fun) when is_function(fun, 2),
    do: :persistent_term.put({@key, :send_keys_fun}, fun)
end
