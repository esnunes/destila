defmodule Destila.Terminal.ServerTest do
  use ExUnit.Case, async: true

  alias Destila.Terminal.Server

  @tag :terminal
  test "starts and stops a terminal server" do
    topic = "terminal:test-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Destila.PubSub, topic)

    {:ok, pid} =
      start_supervised({Server, name: {:global, topic}, cwd: System.tmp_dir!(), topic: topic})

    # The shell should produce some output (prompt)
    assert_receive {:terminal_output, _data}, 5_000

    # Write a command
    Server.write(pid, "echo hello\n")
    assert_receive {:terminal_output, _data}, 5_000

    # Stop
    stop_supervised(Server)
  end
end
