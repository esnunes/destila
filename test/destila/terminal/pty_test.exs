defmodule Destila.Terminal.PTYTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Destila.Terminal.PTY

  setup :set_mimic_global
  setup :verify_on_exit!

  defp spawn_dummy, do: spawn(fn -> Process.sleep(:infinity) end)

  defp capture_callbacks(fake_pty) do
    test_pid = self()

    stub(ExPTY, :spawn, fn _cmd, _args, _opts -> {:ok, fake_pty} end)

    stub(ExPTY, :on_data, fn ^fake_pty, cb ->
      send(test_pid, {:on_data_cb, cb})
      :ok
    end)

    stub(ExPTY, :on_exit, fn ^fake_pty, cb ->
      send(test_pid, {:on_exit_cb, cb})
      :ok
    end)
  end

  test "spawn forwards cmd/args/cwd/cols/rows to ExPTY and returns the pid handle" do
    fake_pty = spawn_dummy()
    test_pid = self()

    expect(ExPTY, :spawn, fn cmd, args, opts ->
      send(test_pid, {:exp_spawn, cmd, args, opts})
      {:ok, fake_pty}
    end)

    stub(ExPTY, :on_data, fn _, _ -> :ok end)
    stub(ExPTY, :on_exit, fn _, _ -> :ok end)

    assert {:ok, ^fake_pty} =
             PTY.spawn(self(),
               cmd: "/usr/bin/env",
               args: ["TERM=xterm-256color", "/bin/sh"],
               cwd: "/tmp",
               cols: 120,
               rows: 40
             )

    assert_receive {:exp_spawn, "/usr/bin/env", ["TERM=xterm-256color", "/bin/sh"], opts}
    assert Keyword.fetch!(opts, :cwd) == "/tmp"
    assert Keyword.fetch!(opts, :cols) == 120
    assert Keyword.fetch!(opts, :rows) == 40
    assert Keyword.fetch!(opts, :closeFDs) == true
  end

  test "on_data callback forwards data to the owner as {:pty_output, handle, data}" do
    fake_pty = spawn_dummy()
    capture_callbacks(fake_pty)

    {:ok, ^fake_pty} =
      PTY.spawn(self(),
        cmd: "/bin/sh",
        args: [],
        cwd: "/tmp",
        cols: 80,
        rows: 24
      )

    assert_receive {:on_data_cb, data_cb}
    data_cb.(fake_pty, self(), "hello")

    assert_receive {:pty_output, ^fake_pty, "hello"}
  end

  test "on_exit with signal == 0 yields {:status, exit_code}" do
    fake_pty = spawn_dummy()
    capture_callbacks(fake_pty)

    {:ok, ^fake_pty} =
      PTY.spawn(self(),
        cmd: "/bin/sh",
        args: [],
        cwd: "/tmp",
        cols: 80,
        rows: 24
      )

    assert_receive {:on_exit_cb, exit_cb}
    exit_cb.(fake_pty, self(), 0, 0)

    assert_receive {:pty_exit, ^fake_pty, {:status, 0}}
  end

  test "on_exit with non-zero signal yields {:signal, signal, false}" do
    fake_pty = spawn_dummy()
    capture_callbacks(fake_pty)

    {:ok, ^fake_pty} =
      PTY.spawn(self(),
        cmd: "/bin/sh",
        args: [],
        cwd: "/tmp",
        cols: 80,
        rows: 24
      )

    assert_receive {:on_exit_cb, exit_cb}
    exit_cb.(fake_pty, self(), 0, 15)

    assert_receive {:pty_exit, ^fake_pty, {:signal, 15, false}}
  end

  test "propagates {:error, reason} from the backend" do
    expect(ExPTY, :spawn, fn _, _, _ -> {:error, "boom"} end)

    assert {:error, "boom"} =
             PTY.spawn(self(),
               cmd: "/bin/sh",
               args: [],
               cwd: "/tmp",
               cols: 80,
               rows: 24
             )
  end

  test "write/resize/kill delegate to ExPTY" do
    fake_pty = spawn_dummy()
    test_pid = self()

    expect(ExPTY, :write, fn ^fake_pty, "abc" ->
      send(test_pid, :wrote)
      :ok
    end)

    expect(ExPTY, :resize, fn ^fake_pty, 120, 40 ->
      send(test_pid, :resized)
      :ok
    end)

    expect(ExPTY, :kill, fn ^fake_pty, 15 ->
      send(test_pid, :killed)
      :ok
    end)

    assert :ok = PTY.write(fake_pty, "abc")
    assert :ok = PTY.resize(fake_pty, 120, 40)
    assert :ok = PTY.kill(fake_pty, 15)

    assert_receive :wrote
    assert_receive :resized
    assert_receive :killed
  end
end
