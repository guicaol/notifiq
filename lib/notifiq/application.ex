defmodule Notifiq.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Fail the boot (not the first request) when a configured adapter is broken.
    Notifiq.Integrations.Registry.validate!()
    Notifiq.Channels.Registry.validate!()

    children = [
      NotifiqWeb.Telemetry,
      Notifiq.Repo,
      {Oban, Application.fetch_env!(:notifiq, Oban)},
      {DNSCluster, query: Application.get_env(:notifiq, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Notifiq.PubSub},
      # Start a worker by calling: Notifiq.Worker.start_link(arg)
      # {Notifiq.Worker, arg},
      # Start to serve requests, typically the last entry
      NotifiqWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Notifiq.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    NotifiqWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
