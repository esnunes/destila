defmodule Destila.AI.AlivenessTrackerTest do
  use ExUnit.Case, async: false

  alias Destila.AI.AlivenessTracker

  test "alive?/1 returns false for unknown session" do
    refute AlivenessTracker.alive?("nonexistent")
  end

  test "tracks session started via PubSub broadcast" do
    session_id = Ecto.UUID.generate()

    # Register a dummy agent in the AI SessionRegistry
    {:ok, pid} =
      Agent.start_link(fn -> nil end,
        name: {:via, Registry, {Destila.AI.SessionRegistry, session_id}}
      )

    # Subscribe to aliveness changes
    Phoenix.PubSub.subscribe(Destila.PubSub, AlivenessTracker.topic())

    # Simulate the broadcast that ClaudeSession.init/1 sends
    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      Destila.PubSubHelper.claude_session_topic(),
      {:claude_session_started, session_id}
    )

    # Wait for the tracker to process the message
    assert_receive {:aliveness_changed, ^session_id, true}

    assert AlivenessTracker.alive?(session_id)

    # Stop the agent — should trigger :DOWN
    Agent.stop(pid)

    assert_receive {:aliveness_changed, ^session_id, false}
    refute AlivenessTracker.alive?(session_id)
  end

  test "initial scan picks up already-running sessions" do
    session_id = Ecto.UUID.generate()

    # Register before notifying tracker
    {:ok, _pid} =
      Agent.start_link(fn -> nil end,
        name: {:via, Registry, {Destila.AI.SessionRegistry, session_id}}
      )

    # Broadcast to notify tracker
    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      Destila.PubSubHelper.claude_session_topic(),
      {:claude_session_started, session_id}
    )

    # Give tracker time to process
    _ = :sys.get_state(AlivenessTracker)

    assert AlivenessTracker.alive?(session_id)
  end
end
