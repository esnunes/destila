defmodule Destila.Services.LogsTest do
  use ExUnit.Case, async: false

  alias Destila.Services.Logs

  setup do
    original = System.get_env("XDG_CACHE_HOME")
    tmp = Path.join(System.tmp_dir!(), "destila-logs-test-#{System.unique_integer([:positive])}")
    System.put_env("XDG_CACHE_HOME", tmp)

    on_exit(fn ->
      if original,
        do: System.put_env("XDG_CACHE_HOME", original),
        else: System.delete_env("XDG_CACHE_HOME")

      File.rm_rf!(tmp)
    end)

    %{cache: tmp}
  end

  describe "log_path/1" do
    test "returns an absolute path ending in destila/services/<log_key>.log" do
      log_key = "session-11111111-1111-1111-1111-111111111111"
      path = Logs.log_path(log_key)
      assert Path.type(path) == :absolute
      assert String.ends_with?(path, "destila/services/#{log_key}.log")
    end
  end

  describe "log_dir/0" do
    test "returns an absolute path ending in destila/services" do
      dir = Logs.log_dir()
      assert Path.type(dir) == :absolute
      assert String.ends_with?(dir, "destila/services")
    end
  end

  describe "ensure_log_dir/0" do
    test "creates the directory if missing and is idempotent" do
      assert :ok = Logs.ensure_log_dir()
      assert File.dir?(Logs.log_dir())
      assert :ok = Logs.ensure_log_dir()
    end
  end
end
