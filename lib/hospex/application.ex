defmodule Hospex.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Hospex.Repo,  # re-enable once PostgreSQL is configured locally
      {DNSCluster, query: Application.get_env(:hospex, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Hospex.PubSub},
      Hospex.Bookings.Store,   # in-memory bookings cache (swap for Repo later)
      Hospex.Inventory.Store,  # in-memory inventory overrides
      # {Oban, Application.fetch_env!(:hospex, Oban)},  # requires database
      HospexWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Hospex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    HospexWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
