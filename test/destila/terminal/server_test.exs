defmodule Destila.Terminal.ServerTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Destila.Terminal.{Server, Tmux}

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    fake_pty =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(fake_pty, :kill) end)

    test_pid = self()

    stub(Tmux, :ensure_session, fn _name, _cwd -> :ok end)
    stub(Tmux, :escape_shell, fn str -> "'#{str}'" end)
    stub(Tmux, :window_exists?, fn _target -> true end)

    stub(ExPTY, :spawn, fn _file, _args, _opts -> {:ok, fake_pty} end)

    stub(ExPTY, :on_data, fn ^fake_pty, cb ->
      send(test_pid, {:on_data_registered, cb})
      :ok
    end)

    stub(ExPTY, :on_exit, fn ^fake_pty, _cb -> :ok end)

    stub(ExPTY, :write, fn ^fake_pty, data ->
      send(test_pid, {:pty_write, data})
      :ok
    end)

    stub(ExPTY, :kill, fn ^fake_pty, _sig -> :ok end)

    {:ok, fake_pty: fake_pty}
  end

  test "broadcasts PTY output and forwards writes without hitting real tmux" do
    topic = "terminal:test-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Destila.PubSub, topic)

    {:ok, pid} =
      start_supervised({Server, cwd: System.tmp_dir!(), topic: topic})

    assert_receive {:on_data_registered, on_data}, 1_000

    on_data.(nil, nil, "prompt$ ")
    assert_receive {:terminal_output, "prompt$ "}, 1_000

    Server.write(pid, "echo hello\n")
    assert_receive {:pty_write, "echo hello\n"}, 1_000

    stop_supervised!(Server)
  end
end
