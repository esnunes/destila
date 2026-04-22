defmodule Destila.Terminal.ServerTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Destila.Terminal.{PTY, Server, Tmux}

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    fake_handle = make_ref()

    test_pid = self()

    stub(Tmux, :ensure_session, fn _name, _cwd -> :ok end)
    stub(Tmux, :escape_shell, fn str -> "'#{str}'" end)
    stub(Tmux, :window_exists?, fn _target -> true end)

    stub(PTY, :spawn, fn owner, opts ->
      send(test_pid, {:pty_spawned, owner, opts, fake_handle})
      {:ok, fake_handle}
    end)

    stub(PTY, :write, fn ^fake_handle, data ->
      send(test_pid, {:pty_write, data})
      :ok
    end)

    stub(PTY, :resize, fn ^fake_handle, cols, rows ->
      send(test_pid, {:pty_resize, cols, rows})
      :ok
    end)

    stub(PTY, :kill, fn ^fake_handle, sig ->
      send(test_pid, {:pty_kill, sig})
      :ok
    end)

    {:ok, fake_handle: fake_handle}
  end

  test "spawns the PTY with expected command, cwd, cols, rows, and owner", %{
    fake_handle: fake_handle
  } do
    topic = "terminal:test-#{System.unique_integer([:positive])}"
    cwd = System.tmp_dir!()

    {:ok, pid} = start_supervised({Server, cwd: cwd, topic: topic, cols: 120, rows: 40})

    assert_receive {:pty_spawned, ^pid, opts, ^fake_handle}, 1_000
    assert Keyword.fetch!(opts, :cmd) == "/usr/bin/env"
    assert Keyword.fetch!(opts, :cwd) == cwd
    assert Keyword.fetch!(opts, :cols) == 120
    assert Keyword.fetch!(opts, :rows) == 40
    args = Keyword.fetch!(opts, :args)
    assert "TERM=xterm-256color" in args
    assert "COLORTERM=truecolor" in args
    assert Enum.any?(args, &String.contains?(&1, "tmux attach"))
  end

  test "broadcasts PTY output and forwards writes without hitting real tmux", %{
    fake_handle: fake_handle
  } do
    topic = "terminal:test-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Destila.PubSub, topic)

    {:ok, pid} = start_supervised({Server, cwd: System.tmp_dir!(), topic: topic})

    assert_receive {:pty_spawned, ^pid, _opts, ^fake_handle}, 1_000

    send(pid, {:pty_output, fake_handle, "prompt$ "})
    assert_receive {:terminal_output, "prompt$ "}, 1_000

    Server.write(pid, "echo hello\n")
    assert_receive {:pty_write, "echo hello\n"}, 1_000
  end

  test "forwards resize to the PTY with cols and rows", %{fake_handle: fake_handle} do
    topic = "terminal:test-#{System.unique_integer([:positive])}"

    {:ok, pid} = start_supervised({Server, cwd: System.tmp_dir!(), topic: topic})

    assert_receive {:pty_spawned, ^pid, _opts, ^fake_handle}, 1_000

    Server.resize(pid, 120, 40)
    assert_receive {:pty_resize, 120, 40}, 1_000
  end

  test "broadcasts :terminal_exited when the wrapper reports a PTY exit", %{
    fake_handle: fake_handle
  } do
    topic = "terminal:test-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Destila.PubSub, topic)

    {:ok, pid} = start_supervised({Server, cwd: System.tmp_dir!(), topic: topic})

    assert_receive {:pty_spawned, ^pid, _opts, ^fake_handle}, 1_000

    send(pid, {:pty_exit, fake_handle, {:status, 0}})
    assert_receive :terminal_exited, 1_000
  end

  test "sends SIGTERM to the PTY on GenServer terminate", %{fake_handle: fake_handle} do
    topic = "terminal:test-#{System.unique_integer([:positive])}"

    {:ok, pid} = start_supervised({Server, cwd: System.tmp_dir!(), topic: topic})

    assert_receive {:pty_spawned, ^pid, _opts, ^fake_handle}, 1_000

    stop_supervised!(Server)
    assert_receive {:pty_kill, 15}, 1_000
  end

  test "stops without re-killing the PTY when {:EXIT, pty, _} arrives", %{
    fake_handle: fake_handle
  } do
    topic = "terminal:test-#{System.unique_integer([:positive])}"

    {:ok, pid} = start_supervised({Server, cwd: System.tmp_dir!(), topic: topic})

    assert_receive {:pty_spawned, ^pid, _opts, ^fake_handle}, 1_000

    ref = Process.monitor(pid)
    send(pid, {:EXIT, fake_handle, :normal})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    refute_received {:pty_kill, _}
  end
end
