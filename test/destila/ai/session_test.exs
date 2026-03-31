defmodule Destila.AI.ClaudeSessionTest do
  use ExUnit.Case, async: true

  describe "start_link/1 and stop/1" do
    test "starts and stops a session" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [ClaudeCode.Test.result("ok")]
      end)

      {:ok, session} = Destila.AI.ClaudeSession.start_link(timeout_ms: :timer.seconds(5))
      ClaudeCode.Test.allow(ClaudeCode, self(), session)

      assert Process.alive?(session)

      Destila.AI.ClaudeSession.stop(session)
      refute Process.alive?(session)
    end
  end

  describe "query/3" do
    test "returns successful result" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.text("Hello world"),
          ClaudeCode.Test.result("Hello world")
        ]
      end)

      {:ok, session} = Destila.AI.ClaudeSession.start_link(timeout_ms: :timer.seconds(5))
      ClaudeCode.Test.allow(ClaudeCode, self(), session)

      assert {:ok, result} = Destila.AI.ClaudeSession.query(session, "say hello")
      assert result.result == "Hello world"

      Destila.AI.ClaudeSession.stop(session)
    end

    test "returns error on failure" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [ClaudeCode.Test.result("Something went wrong", is_error: true)]
      end)

      {:ok, session} = Destila.AI.ClaudeSession.start_link(timeout_ms: :timer.seconds(5))
      ClaudeCode.Test.allow(ClaudeCode, self(), session)

      assert {:error, _result} = Destila.AI.ClaudeSession.query(session, "fail please")

      Destila.AI.ClaudeSession.stop(session)
    end
  end

  describe "query_streaming/3" do
    test "broadcasts stream chunks to the given topic" do
      topic = Destila.PubSubHelper.ai_stream_topic("test-ws-id")
      Phoenix.PubSub.subscribe(Destila.PubSub, topic)

      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.text("Hello "),
          ClaudeCode.Test.text("world"),
          ClaudeCode.Test.result("Hello world")
        ]
      end)

      {:ok, session} = Destila.AI.ClaudeSession.start_link(timeout_ms: :timer.seconds(5))
      ClaudeCode.Test.allow(ClaudeCode, self(), session)

      {:ok, result} =
        Destila.AI.ClaudeSession.query_streaming(session, "test", stream_topic: topic)

      # Verify chunks were broadcast
      assert_received {:ai_stream_chunk, %ClaudeCode.Message.AssistantMessage{}}
      assert_received {:ai_stream_chunk, %ClaudeCode.Message.AssistantMessage{}}
      assert_received {:ai_stream_chunk, %ClaudeCode.Message.ResultMessage{}}

      # Verify final result is still collected correctly
      assert result.text == "Hello world"

      Destila.AI.ClaudeSession.stop(session)
    end
  end

  describe "inactivity timeout" do
    test "session stops after inactivity timeout" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [ClaudeCode.Test.result("ok")]
      end)

      {:ok, session} = Destila.AI.ClaudeSession.start_link(timeout_ms: 50)
      ClaudeCode.Test.allow(ClaudeCode, self(), session)

      ref = Process.monitor(session)
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 500
    end

    test "query resets the inactivity timer" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.text("ok"),
          ClaudeCode.Test.result("ok")
        ]
      end)

      {:ok, session} = Destila.AI.ClaudeSession.start_link(timeout_ms: 100)
      ClaudeCode.Test.allow(ClaudeCode, self(), session)

      # Query at 50ms — should reset the 100ms timer
      Process.sleep(50)
      assert {:ok, _} = Destila.AI.ClaudeSession.query(session, "keep alive")

      # At 100ms from start (50ms after query), session should still be alive
      Process.sleep(50)
      assert Process.alive?(session)

      # Wait for the full timeout after last query
      ref = Process.monitor(session)
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 200
    end
  end
end
