defmodule Destila.Services.ServiceManagerTest do
  @moduledoc """
  Unit tests for the service command builder.
  Feature: features/service_setup_command.feature
  """
  use ExUnit.Case, async: false

  alias Destila.PubSubHelper
  alias Destila.Services.{Logs, ServiceManager}

  @feature "service_setup_command"

  describe "build_service_command/4 without setup_command" do
    @tag feature: @feature,
         scenario: "A project without a setup command keeps its current behavior"
    test "returns run_command prefixed with env export when no setup" do
      assert ServiceManager.build_service_command(nil, "mix phx.server", "PORT", 4712) ==
               "export PORT=4712 && mix phx.server"
    end
  end

  describe "build_service_command/4 with setup_command" do
    @tag feature: @feature,
         scenario: "Setup and run are chained with ; so setup failure does not block run"
    test "chains setup and run with ; and prefixes the env export" do
      assert ServiceManager.build_service_command("setup", "run", "PORT", 4712) ==
               "export PORT=4712 && setup; run"
    end

    @tag feature: @feature,
         scenario:
           "Start/restart allocates a port and exports the service env var for both setup and run"
    test "exposes the env var to both setup and run commands" do
      result =
        ServiceManager.build_service_command("mix deps.get", "mix phx.server", "API_PORT", 4001)

      assert result == "export API_PORT=4001 && mix deps.get; mix phx.server"
    end
  end

  describe "build_service_command/4 edge cases" do
    @tag feature: @feature, scenario: "Empty setup_command behaves like nil"
    test "treats empty-string setup_command like nil" do
      assert ServiceManager.build_service_command("", "run", "PORT", 4712) ==
               "export PORT=4712 && run"
    end

    @tag feature: @feature, scenario: "Empty setup_command behaves like nil"
    test "treats whitespace-only setup_command like nil" do
      assert ServiceManager.build_service_command("   ", "run", "PORT", 4712) ==
               "export PORT=4712 && run"
    end
  end

  describe "build_service_command/4 placeholder substitution" do
    @tag feature: @feature,
         scenario: "Run command placeholder {ENV_VAR} is substituted with the allocated port"
    test "substitutes {PORT} in run_command without setup" do
      assert ServiceManager.build_service_command(
               nil,
               "elixir --sname destila-{PORT} -S mix phx.server",
               "PORT",
               1234
             ) ==
               "export PORT=1234 && elixir --sname destila-1234 -S mix phx.server"
    end

    @tag feature: @feature,
         scenario: "Run command placeholder {ENV_VAR} is substituted with the allocated port"
    test "substitutes {PORT} in run_command while leaving setup untouched" do
      assert ServiceManager.build_service_command(
               "mix deps.get",
               "mix phx.server --port {PORT}",
               "PORT",
               4712
             ) ==
               "export PORT=4712 && mix deps.get; mix phx.server --port 4712"
    end

    @tag feature: @feature,
         scenario: "Run command placeholder {ENV_VAR} is substituted with the allocated port"
    test "substitutes every occurrence of the placeholder" do
      assert ServiceManager.build_service_command(nil, "a {PORT} b {PORT} c", "PORT", 9000) ==
               "export PORT=9000 && a 9000 b 9000 c"
    end

    @tag feature: @feature,
         scenario: "Run command placeholder {ENV_VAR} is substituted with the allocated port"
    test "leaves placeholders with a different identifier untouched" do
      assert ServiceManager.build_service_command(nil, "app --port {API_PORT}", "PORT", 1234) ==
               "export PORT=1234 && app --port {API_PORT}"
    end

    @tag feature: @feature,
         scenario: "Run command placeholder {ENV_VAR} is substituted with the allocated port"
    test "substitution is case-sensitive" do
      assert ServiceManager.build_service_command(nil, "app --port {port}", "PORT", 1234) ==
               "export PORT=1234 && app --port {port}"
    end

    @tag feature: @feature,
         scenario: "Run command placeholder {ENV_VAR} is substituted with the allocated port"
    test "does not substitute placeholders in setup_command" do
      assert ServiceManager.build_service_command("setup {PORT}", "run", "PORT", 1234) ==
               "export PORT=1234 && setup {PORT}; run"
    end

    @tag feature: @feature,
         scenario: "Run command placeholder {ENV_VAR} is substituted with the allocated port"
    test "substitutes placeholders whose identifier contains underscores and digits" do
      assert ServiceManager.build_service_command(
               nil,
               "app --bind 0.0.0.0:{API_PORT}",
               "API_PORT",
               8081
             ) ==
               "export API_PORT=8081 && app --bind 0.0.0.0:8081"
    end

    test "leaves placeholders untouched when env_var is nil" do
      assert ServiceManager.build_service_command(nil, "run {PORT}", nil, 1234) ==
               "export =1234 && run {PORT}"
    end

    @tag feature: @feature,
         scenario: "A project without a setup command keeps its current behavior"
    test "run_command without placeholder is byte-for-byte unchanged" do
      assert ServiceManager.build_service_command(nil, "mix phx.server", "PORT", 4712) ==
               "export PORT=4712 && mix phx.server"
    end
  end

  describe "reserve_port/0" do
    test "returns an integer port" do
      port = ServiceManager.reserve_port()
      assert is_integer(port)
      assert port > 0
    end
  end

  describe "clear_logs/1" do
    test "truncates the log file and broadcasts a clear event" do
      ws_id = "smtest-" <> Integer.to_string(System.unique_integer([:positive]))
      path = Logs.log_path("session-" <> ws_id)
      Logs.ensure_log_dir()
      File.write!(path, "old logs here")

      Phoenix.PubSub.subscribe(Destila.PubSub, PubSubHelper.service_topic(ws_id))

      assert :ok = ServiceManager.clear_logs(%{id: ws_id})

      assert File.read!(path) == ""
      assert_receive {:service_logs_cleared, ^ws_id}

      File.rm(path)
    end
  end
end
