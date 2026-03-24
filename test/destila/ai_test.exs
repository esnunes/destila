defmodule Destila.AITest do
  use ExUnit.Case, async: true

  describe "generate_title/2 (one-off, no session)" do
    test "returns title for a chore/task" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.text("Dark Mode Toggle"),
          ClaudeCode.Test.result("Dark Mode Toggle")
        ]
      end)

      assert {:ok, "Dark Mode Toggle"} =
               Destila.AI.generate_title(:prompt_chore_task, "add dark mode")
    end

    test "returns title for a project" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.text("Recipe Sharing Platform"),
          ClaudeCode.Test.result("Recipe Sharing Platform")
        ]
      end)

      assert {:ok, "Recipe Sharing Platform"} =
               Destila.AI.generate_title(:prompt_new_project, "a platform to share recipes")
    end

    test "trims whitespace from the title" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.text("  Trimmed Title  \n"),
          ClaudeCode.Test.result("  Trimmed Title  \n")
        ]
      end)

      assert {:ok, "Trimmed Title"} = Destila.AI.generate_title(:prompt_chore_task, "something")
    end

    test "returns error when response is empty" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.text(""),
          ClaudeCode.Test.result("")
        ]
      end)

      assert {:error, :empty_response} =
               Destila.AI.generate_title(:prompt_chore_task, "something")
    end

    test "returns error when response is only whitespace" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.text("   \n  "),
          ClaudeCode.Test.result("   \n  ")
        ]
      end)

      assert {:error, :empty_response} =
               Destila.AI.generate_title(:prompt_chore_task, "something")
    end

    test "returns error on API failure" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.result("Rate limit exceeded", is_error: true)
        ]
      end)

      assert {:error, _reason} = Destila.AI.generate_title(:prompt_new_project, "something")
    end

    test "passes correct options to ClaudeCode" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, opts ->
        assert opts[:model] == "haiku"
        assert opts[:max_turns] == 1
        assert is_binary(opts[:system_prompt])

        [
          ClaudeCode.Test.text("Test Title"),
          ClaudeCode.Test.result("Test Title")
        ]
      end)

      Destila.AI.generate_title(:prompt_chore_task, "test idea")
    end

    test "includes workflow type in the prompt" do
      ClaudeCode.Test.stub(ClaudeCode, fn query, _opts ->
        assert query =~ "chore/task"

        [
          ClaudeCode.Test.text("Test Title"),
          ClaudeCode.Test.result("Test Title")
        ]
      end)

      Destila.AI.generate_title(:prompt_chore_task, "test idea")

      ClaudeCode.Test.stub(ClaudeCode, fn query, _opts ->
        assert query =~ "project"

        [
          ClaudeCode.Test.text("Test Title"),
          ClaudeCode.Test.result("Test Title")
        ]
      end)

      Destila.AI.generate_title(:prompt_new_project, "test idea")
    end

    test "includes idea in the prompt" do
      ClaudeCode.Test.stub(ClaudeCode, fn query, _opts ->
        assert query =~ "build a REST API"

        [
          ClaudeCode.Test.text("REST API Builder"),
          ClaudeCode.Test.result("REST API Builder")
        ]
      end)

      Destila.AI.generate_title(:prompt_new_project, "build a REST API")
    end
  end

  describe "generate_title/3 (with session)" do
    test "returns title through a session" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.text("Session Title"),
          ClaudeCode.Test.result("Session Title")
        ]
      end)

      {:ok, session} = Destila.AI.Session.start_link(timeout_ms: :timer.seconds(5))
      ClaudeCode.Test.allow(ClaudeCode, self(), session)

      assert {:ok, "Session Title"} =
               Destila.AI.generate_title(session, :prompt_chore_task, "add dark mode")

      Destila.AI.Session.stop(session)
    end

    test "trims whitespace from session response" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.text("  Padded Title  \n"),
          ClaudeCode.Test.result("  Padded Title  \n")
        ]
      end)

      {:ok, session} = Destila.AI.Session.start_link(timeout_ms: :timer.seconds(5))
      ClaudeCode.Test.allow(ClaudeCode, self(), session)

      assert {:ok, "Padded Title"} =
               Destila.AI.generate_title(session, :prompt_new_project, "something")

      Destila.AI.Session.stop(session)
    end

    test "returns error when session response is empty" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.text(""),
          ClaudeCode.Test.result("")
        ]
      end)

      {:ok, session} = Destila.AI.Session.start_link(timeout_ms: :timer.seconds(5))
      ClaudeCode.Test.allow(ClaudeCode, self(), session)

      assert {:error, :empty_response} =
               Destila.AI.generate_title(session, :prompt_chore_task, "something")

      Destila.AI.Session.stop(session)
    end

    test "returns error on session API failure" do
      ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
        [
          ClaudeCode.Test.result("Rate limit exceeded", is_error: true)
        ]
      end)

      {:ok, session} = Destila.AI.Session.start_link(timeout_ms: :timer.seconds(5))
      ClaudeCode.Test.allow(ClaudeCode, self(), session)

      assert {:error, _reason} =
               Destila.AI.generate_title(session, :prompt_new_project, "something")

      Destila.AI.Session.stop(session)
    end
  end
end
