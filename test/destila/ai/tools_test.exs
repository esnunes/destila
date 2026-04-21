defmodule Destila.AI.ToolsTest do
  use ExUnit.Case, async: true

  alias Destila.AI.Tools

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

    test "stopped state without port omits url and preserves commands" do
      state = %{
        "status" => "stopped",
        "run_command" => "mix phx.server",
        "setup_command" => "mix deps.get"
      }

      output = Tools.service_state_to_output(state)

      assert output["status"] == "stopped"
      assert output["run_command"] == "mix phx.server"
      assert output["setup_command"] == "mix deps.get"
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
