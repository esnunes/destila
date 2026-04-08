defmodule Mix.Tasks.Destila.SetupTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "run/1" do
    test "reports binary already available when found" do
      output = capture_io(fn -> Mix.Tasks.Destila.Setup.run([]) end)

      assert output =~ "Claude CLI already available at"
    end
  end
end
