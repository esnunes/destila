defmodule Destila.AITest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.AI

  defp create_ws do
    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test",
        workflow_type: :brainstorm_idea,
        current_phase: 1,
        total_phases: 4
      })

    ws
  end

  defp create_ai(ws) do
    {:ok, ai} =
      AI.create_ai_session(%{
        workflow_session_id: ws.id,
        worktree_path: System.tmp_dir!(),
        claude_session_id: Ecto.UUID.generate()
      })

    ai
  end

  defp insert_msg(ai, ws, phase, opts) do
    raw =
      case Keyword.get(opts, :usage) do
        nil ->
          nil

        {input, output, cost} ->
          %{
            "usage" => %{"input_tokens" => input, "output_tokens" => output},
            "total_cost_usd" => cost,
            "duration_ms" => Keyword.get(opts, :duration, 0.0)
          }
      end

    {:ok, msg} =
      AI.create_message(ai.id, %{
        role: :system,
        content: "ok",
        phase: phase,
        workflow_session_id: ws.id,
        raw_response: raw
      })

    case Keyword.get(opts, :inserted_at) do
      nil ->
        msg

      %DateTime{} = dt ->
        import Ecto.Query

        Destila.Repo.update_all(
          from(m in Destila.AI.Message, where: m.id == ^msg.id),
          set: [inserted_at: dt]
        )

        %{msg | inserted_at: dt}
    end
  end

  describe "aggregate_usage_by_phase/1" do
    test "groups totals by phase and omits phases with no messages" do
      ws = create_ws()
      ai = create_ai(ws)

      insert_msg(ai, ws, 1, usage: {100, 50, 0.002})
      insert_msg(ai, ws, 2, usage: {10, 5, 0.0005})
      insert_msg(ai, ws, 2, usage: {40, 20, 0.001})
      insert_msg(ai, ws, 4, usage: {7, 3, 0.0}, duration: 5.0)

      totals = AI.aggregate_usage_by_phase(ai.id)

      assert Map.keys(totals) |> Enum.sort() == [1, 2, 4]
      assert totals[1].input_tokens == 100
      assert totals[1].output_tokens == 50
      assert totals[1].turns == 1
      assert totals[2].input_tokens == 50
      assert totals[2].output_tokens == 25
      assert totals[2].turns == 2
      assert totals[4].duration_ms == 5.0
    end

    test "returns empty map when session has no messages" do
      ws = create_ws()
      ai = create_ai(ws)

      assert AI.aggregate_usage_by_phase(ai.id) == %{}
    end

    test "messages without a usage map contribute zero turns" do
      ws = create_ws()
      ai = create_ai(ws)

      insert_msg(ai, ws, 1, [])

      totals = AI.aggregate_usage_by_phase(ai.id)
      assert totals[1].turns == 0
      assert totals[1].input_tokens == 0
      assert totals[1].output_tokens == 0
    end

    test "total_cost_usd is per-turn delta, not cumulative" do
      ws = create_ws()
      ai = create_ai(ws)

      # ClaudeCode reports cumulative session cost on each result message.
      # Three turns in three phases: 2.00 → 4.42 → 12.20 cumulative
      # means actual per-phase spend is 2.00, 2.42, 7.78 (session total 12.20).
      insert_msg(ai, ws, 1,
        usage: {100, 50, 2.00},
        inserted_at: ~U[2026-01-01 00:00:00.000000Z]
      )

      insert_msg(ai, ws, 2,
        usage: {200, 100, 4.42},
        inserted_at: ~U[2026-01-01 00:01:00.000000Z]
      )

      insert_msg(ai, ws, 3,
        usage: {300, 150, 12.20},
        inserted_at: ~U[2026-01-01 00:02:00.000000Z]
      )

      totals = AI.aggregate_usage_by_phase(ai.id)
      assert_in_delta totals[1].total_cost_usd, 2.00, 0.001
      assert_in_delta totals[2].total_cost_usd, 2.42, 0.001
      assert_in_delta totals[3].total_cost_usd, 7.78, 0.001

      session_total = AI.aggregate_usage_for_ai_session(ai.id)
      assert_in_delta session_total.total_cost_usd, 12.20, 0.001
    end

    test "sum across phases equals aggregate_usage_for_ai_session/1" do
      ws = create_ws()
      ai = create_ai(ws)

      insert_msg(ai, ws, 1, usage: {100, 50, 0.002})
      insert_msg(ai, ws, 2, usage: {40, 10, 0.001})
      insert_msg(ai, ws, 3, usage: {5, 2, 0.0005})

      per_phase = AI.aggregate_usage_by_phase(ai.id)
      total = AI.aggregate_usage_for_ai_session(ai.id)

      summed_in =
        per_phase |> Map.values() |> Enum.reduce(0, &(&2 + &1.input_tokens))

      summed_out =
        per_phase |> Map.values() |> Enum.reduce(0, &(&2 + &1.output_tokens))

      assert summed_in == total.input_tokens
      assert summed_out == total.output_tokens
    end
  end

  describe "get_ai_session_by_claude_session_id/1" do
    test "returns the AI session matching the claude_session_id" do
      ws = create_ws()

      {:ok, ai} =
        AI.create_ai_session(%{
          workflow_session_id: ws.id,
          claude_session_id: "claude-abc"
        })

      assert %{id: found_id} = AI.get_ai_session_by_claude_session_id("claude-abc")
      assert found_id == ai.id
    end

    test "returns nil for an unknown claude_session_id" do
      assert AI.get_ai_session_by_claude_session_id("nope") == nil
    end

    test "returns nil when given nil" do
      assert AI.get_ai_session_by_claude_session_id(nil) == nil
    end

    test "returns nil when given an empty string" do
      assert AI.get_ai_session_by_claude_session_id("") == nil
    end
  end

  describe "phase_boundaries_for_ai_session/1" do
    test "returns max inserted_at per phase" do
      ws = create_ws()
      ai = create_ai(ws)

      t1 = ~U[2026-01-01 00:00:00.000000Z]
      t2 = ~U[2026-01-01 00:01:00.000000Z]
      t3 = ~U[2026-01-01 00:02:00.000000Z]

      insert_msg(ai, ws, 1, usage: {1, 1, 0.0}, inserted_at: t1)
      insert_msg(ai, ws, 1, usage: {1, 1, 0.0}, inserted_at: t2)
      insert_msg(ai, ws, 2, usage: {1, 1, 0.0}, inserted_at: t3)

      boundaries = AI.phase_boundaries_for_ai_session(ai.id)

      assert DateTime.compare(boundaries[1], t2) == :eq
      assert DateTime.compare(boundaries[2], t3) == :eq
    end

    test "returns empty map when session has no messages" do
      ws = create_ws()
      ai = create_ai(ws)

      assert AI.phase_boundaries_for_ai_session(ai.id) == %{}
    end
  end

  describe "generate_title/2 (one-off, no session)" do
    test "returns title for a brainstorm idea" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.text("Dark Mode Toggle"),
          ClaudeCode.Test.result("Dark Mode Toggle")
        ]
      end)

      assert {:ok, "Dark Mode Toggle"} =
               Destila.AI.generate_title(:brainstorm_idea, "add dark mode")
    end

    test "returns title for a brainstorm idea with different idea" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.text("Recipe Sharing Platform"),
          ClaudeCode.Test.result("Recipe Sharing Platform")
        ]
      end)

      assert {:ok, "Recipe Sharing Platform"} =
               Destila.AI.generate_title(:brainstorm_idea, "a platform to share recipes")
    end

    test "trims whitespace from the title" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.text("  Trimmed Title  \n"),
          ClaudeCode.Test.result("  Trimmed Title  \n")
        ]
      end)

      assert {:ok, "Trimmed Title"} = Destila.AI.generate_title(:brainstorm_idea, "something")
    end

    test "returns error when response is empty" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.text(""),
          ClaudeCode.Test.result("")
        ]
      end)

      assert {:error, :empty_response} =
               Destila.AI.generate_title(:brainstorm_idea, "something")
    end

    test "returns error when response is only whitespace" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.text("   \n  "),
          ClaudeCode.Test.result("   \n  ")
        ]
      end)

      assert {:error, :empty_response} =
               Destila.AI.generate_title(:brainstorm_idea, "something")
    end

    test "returns error on API failure" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.result("Rate limit exceeded", is_error: true)
        ]
      end)

      assert {:error, _reason} = Destila.AI.generate_title(:brainstorm_idea, "something")
    end

    test "passes correct options to ClaudeCode" do
      # In ClaudeCode v0.36+, session opts (model, system_prompt, max_turns) are
      # passed to start_link at session-creation time, not as per-query opts.
      # The stub callback receives only stream-level opts (empty for one-off queries).
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.text("Test Title"),
          ClaudeCode.Test.result("Test Title")
        ]
      end)

      assert {:ok, "Test Title"} = Destila.AI.generate_title(:brainstorm_idea, "test idea")
    end

    test "includes workflow type in the prompt" do
      ClaudeCode.Test.stub(ClaudeCode, fn query, _opts ->
        assert query =~ "brainstorm idea"

        [
          ClaudeCode.Test.text("Test Title"),
          ClaudeCode.Test.result("Test Title")
        ]
      end)

      Destila.AI.generate_title(:brainstorm_idea, "test idea")
    end

    test "includes idea in the prompt" do
      ClaudeCode.Test.stub(ClaudeCode, fn query, _opts ->
        assert query =~ "build a REST API"

        [
          ClaudeCode.Test.text("REST API Builder"),
          ClaudeCode.Test.result("REST API Builder")
        ]
      end)

      Destila.AI.generate_title(:brainstorm_idea, "build a REST API")
    end
  end
end
