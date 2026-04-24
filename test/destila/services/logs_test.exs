defmodule Destila.Services.LogsTest do
  use ExUnit.Case, async: true

  alias Destila.Services.Logs

  describe "log_path/1" do
    test "returns an absolute path ending in tmp/services/<ws_id>.log" do
      ws_id = "11111111-1111-1111-1111-111111111111"
      path = Logs.log_path(ws_id)
      assert Path.type(path) == :absolute
      assert String.ends_with?(path, "tmp/services/#{ws_id}.log")
    end
  end

  describe "log_dir/0" do
    test "returns an absolute path ending in tmp/services" do
      dir = Logs.log_dir()
      assert Path.type(dir) == :absolute
      assert String.ends_with?(dir, "tmp/services")
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
