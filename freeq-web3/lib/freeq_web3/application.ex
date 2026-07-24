defmodule FreeqWeb3.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FreeqWeb3Web.Telemetry,
      {DNSCluster, query: Application.get_env(:freeq_web3, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: FreeqWeb3.PubSub},
      # Per-browser IRC sessions (BFF): Registry + DynamicSupervisor.
      {Registry, keys: :unique, name: FreeqWeb3.Session.Registry},
      FreeqWeb3.Session.Supervisor,
      # Start to serve requests, typically the last entry
      FreeqWeb3Web.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FreeqWeb3.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FreeqWeb3Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
