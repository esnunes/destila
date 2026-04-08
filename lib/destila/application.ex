defmodule Destila.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        DestilaWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:destila, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Destila.PubSub},
        Destila.Repo,
        {Oban, Application.fetch_env!(:destila, Oban)},
        {Registry, keys: :unique, name: Destila.AI.SessionRegistry},
        {DynamicSupervisor, name: Destila.AI.SessionSupervisor, strategy: :one_for_one},
        {Registry, keys: :unique, name: Destila.Sessions.Registry},
        {DynamicSupervisor, name: Destila.Sessions.Supervisor, strategy: :one_for_one},
        DestilaWeb.Endpoint
      ] ++ claude_cli_warmer()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Destila.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The Claude CLI warmer pre-installs and exercises the bundled CLI binary so
  # the first real user request does not pay the install cost or hit the macOS
  # Gatekeeper SIGKILL race. Skipped under the test adapter, which never spawns
  # the real CLI.
  defp claude_cli_warmer do
    case Application.get_env(:claude_code, :adapter) do
      {ClaudeCode.Test, _} -> []
      _ -> [Destila.AI.CliWarmer]
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DestilaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
