defmodule Destila.AITest do
  use ExUnit.Case, async: true

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
      ClaudeCode.Test.stub(ClaudeCode, fn _query, opts ->
        assert opts[:model] == "haiku"
        assert opts[:max_turns] == 1
        assert is_binary(opts[:system_prompt])

        [
          ClaudeCode.Test.text("Test Title"),
          ClaudeCode.Test.result("Test Title")
        ]
      end)

      Destila.AI.generate_title(:brainstorm_idea, "test idea")
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
