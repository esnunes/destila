defmodule Destila.Services.LogTailerTest do
  use ExUnit.Case, async: false

  alias Destila.PubSubHelper
  alias Destila.Services.{LogTailer, Logs}

  setup do
    ws_id = "tailer-test-" <> Integer.to_string(System.unique_integer([:positive]))
    path = Logs.log_path(ws_id)
    Logs.ensure_log_dir()
    File.rm(path)

    on_exit(fn ->
      LogTailer.stop_for(ws_id)
      File.rm(path)
    end)

    Phoenix.PubSub.subscribe(Destila.PubSub, PubSubHelper.service_topic(ws_id))

    {:ok, ws_id: ws_id, path: path}
  end

  test "broadcasts new bytes written to the log file", %{ws_id: ws_id, path: path} do
    File.write!(path, "")
    {:ok, _pid} = LogTailer.start_for(ws_id)

    File.write!(path, "hello\n")

    assert_receive {:service_log, "hello\n"}, 1_500
  end

  test "resets and re-broadcasts from start when file is truncated",
       %{ws_id: ws_id, path: path} do
    File.write!(path, "")
    {:ok, pid} = LogTailer.start_for(ws_id)

    File.write!(path, "first\n")
    assert_receive {:service_log, "first\n"}, 1_500

    # External truncation — wait for the tailer to observe it before writing new content.
    File.write!(path, "")
    wait_until(fn -> :sys.get_state(pid).position == 0 end)

    File.write!(path, "second\n")
    assert_receive {:service_log, "second\n"}, 2_000
  end

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> raise "wait_until/1 timed out"
      true -> wait_until(fun, deadline)
    end
  end

  test "stop_for/1 terminates the process", %{ws_id: ws_id, path: path} do
    File.write!(path, "")
    {:ok, pid} = LogTailer.start_for(ws_id)
    ref = Process.monitor(pid)

    :ok = LogTailer.stop_for(ws_id)

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    wait_until(fn -> LogTailer.whereis(ws_id) == :error end)
  end

  test "start_for/1 is idempotent — second call reuses the first pid", %{ws_id: ws_id, path: path} do
    File.write!(path, "")
    {:ok, pid1} = LogTailer.start_for(ws_id)
    {:ok, pid2} = LogTailer.start_for(ws_id)
    assert pid1 == pid2
  end

  test "broadcasts nothing on init when file is empty", %{ws_id: ws_id, path: path} do
    File.write!(path, "")
    {:ok, _pid} = LogTailer.start_for(ws_id)

    # A full poll interval has to pass without a broadcast.
    refute_receive {:service_log, _}, 500
  end
end
