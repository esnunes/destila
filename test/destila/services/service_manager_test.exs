defmodule Destila.Services.ServiceManagerTest do
  @moduledoc """
  Unit tests for the service command builder.
  Feature: features/service_setup_command.feature
  """
  use ExUnit.Case, async: true

  alias Destila.Services.ServiceManager

  @feature "service_setup_command"

  describe "build_service_command/3 without setup_command" do
    @tag feature: @feature, scenario: "Run command without setup runs unchanged"
    test "returns run_command unchanged when no setup and no ports" do
      assert ServiceManager.build_service_command(nil, "mix phx.server", %{}) ==
               "mix phx.server"
    end

    @tag feature: @feature, scenario: "Run command without setup runs unchanged"
    test "prepends port exports with && when no setup" do
      result =
        ServiceManager.build_service_command(
          nil,
          "mix phx.server",
          %{"PORT" => 4000, "API_PORT" => 4001}
        )

      assert result =~ "export PORT=4000"
      assert result =~ "export API_PORT=4001"
      assert result =~ " && mix phx.server"
      refute result =~ ";"
    end
  end

  describe "build_service_command/3 with setup_command" do
    @tag feature: @feature,
         scenario: "Setup and run are chained with ; so setup failure does not block run"
    test "chains setup and run with ; when no ports" do
      assert ServiceManager.build_service_command(
               "mix deps.get",
               "mix phx.server",
               %{}
             ) == "mix deps.get; mix phx.server"
    end

    @tag feature: @feature,
         scenario: "Setup and run are chained with ; so setup failure does not block run"
    test "exports ports with &&, then chains setup and run with ;" do
      result =
        ServiceManager.build_service_command(
          "mix deps.get",
          "mix phx.server",
          %{"PORT" => 4000, "API_PORT" => 4001}
        )

      assert result =~ "export PORT=4000"
      assert result =~ "export API_PORT=4001"
      assert result =~ " && mix deps.get; mix phx.server"
    end
  end

  describe "build_service_command/3 edge cases" do
    @tag feature: @feature, scenario: "Empty setup_command behaves like nil"
    test "treats empty-string setup_command like nil" do
      assert ServiceManager.build_service_command("", "mix phx.server", %{}) ==
               "mix phx.server"
    end

    @tag feature: @feature, scenario: "Empty setup_command behaves like nil"
    test "treats whitespace-only setup_command like nil" do
      assert ServiceManager.build_service_command("   ", "mix phx.server", %{}) ==
               "mix phx.server"
    end

    test "empty ports map behaves like no ports" do
      assert ServiceManager.build_service_command(nil, "run", %{}) == "run"
      assert ServiceManager.build_service_command("setup", "run", %{}) == "setup; run"
    end
  end
end
