defmodule Destila.AI.ToolsTest do
  use ExUnit.Case, async: true

  alias Destila.AI.Tools

  describe "tool_descriptions/1" do
    test "returns description for mcp__destila__session" do
      result = Tools.tool_descriptions(["mcp__destila__session"])
      assert result =~ "Phase Transitions"
      assert result =~ "suggest_phase_complete"
      assert result =~ "Exporting Data"
    end

    test "returns description for mcp__destila__ask_user_question" do
      result = Tools.tool_descriptions(["mcp__destila__ask_user_question"])
      assert result =~ "Asking Questions"
      assert result =~ "mcp__destila__ask_user_question"
    end

    test "returns descriptions for multiple tools" do
      result =
        Tools.tool_descriptions(["mcp__destila__ask_user_question", "mcp__destila__session"])

      assert result =~ "Asking Questions"
      assert result =~ "Phase Transitions"
      assert result =~ "Exporting Data"
    end

    test "ignores tools without descriptions" do
      result = Tools.tool_descriptions(["Read", "Write", "mcp__destila__session"])
      refute result =~ "Read"
      assert result =~ "Phase Transitions"
    end

    test "returns empty string when no tools have descriptions" do
      assert Tools.tool_descriptions(["Read", "Write", "Bash"]) == ""
    end
  end

  describe "described_tool_names/0" do
    test "returns destila tool names" do
      names = Tools.described_tool_names()
      assert "mcp__destila__session" in names
      assert "mcp__destila__ask_user_question" in names
    end
  end

  describe "service_state_to_output/1" do
    test "running state with port includes url" do
      state = %{
        "status" => "running",
        "port" => 4712,
        "run_command" => "mix phx.server",
        "setup_command" => "mix deps.get"
      }

      output = Tools.service_state_to_output(state)

      assert output["status"] == "running"
      assert output["url"] == "http://localhost:4712"
      assert output["run_command"] == "mix phx.server"
      assert output["setup_command"] == "mix deps.get"
    end

    test "starting state with port includes url" do
      state = %{
        "status" => "starting",
        "port" => 4712,
        "run_command" => "run",
        "setup_command" => nil
      }

      output = Tools.service_state_to_output(state)

      assert output["status"] == "starting"
      assert output["url"] == "http://localhost:4712"
    end

    test "stopped state without port omits url" do
      state = %{"status" => "stopped", "run_command" => "run", "setup_command" => nil}

      output = Tools.service_state_to_output(state)

      assert output["status"] == "stopped"
      refute Map.has_key?(output, "url")
    end

    test "legacy state with ports map omits url" do
      state = %{"status" => "running", "ports" => %{"PORT" => 4712}}

      output = Tools.service_state_to_output(state)

      refute Map.has_key?(output, "url")
    end

    test "serializes to JSON without a url key when no port" do
      state = %{"status" => "stopped", "run_command" => "run", "setup_command" => nil}
      json = Jason.encode!(Tools.service_state_to_output(state))
      refute json =~ "url"
      assert json =~ ~s("status":"stopped")
    end
  end
end
