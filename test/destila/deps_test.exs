defmodule Destila.DepsTest do
  use ExUnit.Case, async: true

  alias Destila.Deps

  describe "check/0" do
    test "returns the expected four tools in order" do
      names = Enum.map(Deps.check(), & &1.name)
      assert names == ["claude", "tmux", "ffmpeg", "agent-browser"]
    end

    test "each tool carries the expected metadata keys" do
      for tool <- Deps.check() do
        assert is_binary(tool.name)
        assert is_binary(tool.display_name)
        assert is_binary(tool.purpose)
        assert is_binary(tool.install_command)
        assert is_binary(tool.docs_url)
        assert is_boolean(tool.available?)
      end
    end
  end
end
