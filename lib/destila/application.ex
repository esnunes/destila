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
        Destila.AI.AlivenessTracker,
        {Registry, keys: :unique, name: Destila.Sessions.Registry},
        {DynamicSupervisor, name: Destila.Sessions.Supervisor, strategy: :one_for_one},
        {Registry, keys: :unique, name: Destila.Services.LogTailerRegistry},
        {DynamicSupervisor, name: Destila.Services.LogTailerSupervisor, strategy: :one_for_one},
        {Registry, keys: :unique, name: Destila.Agent.SessionRegistry},
        {DynamicSupervisor, name: Destila.Agent.SessionSupervisor, strategy: :one_for_one},
        DestilaWeb.Endpoint
      ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Destila.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _pid} = ok ->
        Task.start(fn -> Destila.Services.ProjectServices.resume_all() end)

        Task.start(fn ->
          try do
            Destila.Agent.WorkflowLoader.load_all()
          rescue
            e ->
              require Logger

              Logger.error(
                "Destila.Agent.WorkflowLoader.load_all/0 failed at boot: #{Exception.message(e)}"
              )
          end
        end)

        ok

      other ->
        other
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
