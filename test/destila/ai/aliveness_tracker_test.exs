defmodule Destila.AI.AlivenessTrackerTest do
  use ExUnit.Case, async: false

  alias Destila.AI.AlivenessTracker

  setup do
    Phoenix.PubSub.subscribe(Destila.PubSub, AlivenessTracker.topic())
    :ok
  end

  test "alive?/1 returns false for unknown session" do
    refute AlivenessTracker.alive?("nonexistent")
  end

  test "alive_ai?/1 returns false for unknown ai session" do
    refute AlivenessTracker.alive_ai?("nonexistent")
  end

  test "tracks workflow and ai session started via 3-tuple PubSub broadcast" do
    workflow_session_id = Ecto.UUID.generate()
    ai_session_id = Ecto.UUID.generate()

    {:ok, pid} =
      Agent.start_link(fn -> nil end,
        name: {:via, Registry, {Destila.AI.SessionRegistry, workflow_session_id}}
      )

    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      Destila.PubSubHelper.claude_session_topic(),
      {:claude_session_started, workflow_session_id, ai_session_id}
    )

    assert_receive {:aliveness_changed, ^workflow_session_id, true}
    assert_receive {:aliveness_changed_ai, ^ai_session_id, true}

    assert AlivenessTracker.alive?(workflow_session_id)
    assert AlivenessTracker.alive_ai?(ai_session_id)

    Agent.stop(pid)

    assert_receive {:aliveness_changed, ^workflow_session_id, false}
    assert_receive {:aliveness_changed_ai, ^ai_session_id, false}
    refute AlivenessTracker.alive?(workflow_session_id)
    refute AlivenessTracker.alive_ai?(ai_session_id)
  end

  test "tracks workflow without ai_session_id via legacy 2-tuple broadcast" do
    workflow_session_id = Ecto.UUID.generate()

    {:ok, pid} =
      Agent.start_link(fn -> nil end,
        name: {:via, Registry, {Destila.AI.SessionRegistry, workflow_session_id}}
      )

    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      Destila.PubSubHelper.claude_session_topic(),
      {:claude_session_started, workflow_session_id}
    )

    assert_receive {:aliveness_changed, ^workflow_session_id, true}
    assert AlivenessTracker.alive?(workflow_session_id)

    Agent.stop(pid)

    assert_receive {:aliveness_changed, ^workflow_session_id, false}
    refute AlivenessTracker.alive?(workflow_session_id)
  end

  test "initial scan picks up already-running sessions" do
    workflow_session_id = Ecto.UUID.generate()

    {:ok, _pid} =
      Agent.start_link(fn -> nil end,
        name: {:via, Registry, {Destila.AI.SessionRegistry, workflow_session_id}}
      )

    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      Destila.PubSubHelper.claude_session_topic(),
      {:claude_session_started, workflow_session_id, nil}
    )

    _ = :sys.get_state(AlivenessTracker)

    assert AlivenessTracker.alive?(workflow_session_id)
  end
end
