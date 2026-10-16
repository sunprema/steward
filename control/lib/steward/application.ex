defmodule Steward.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      StewardWeb.Telemetry,
      Steward.Repo,
      {DNSCluster, query: Application.get_env(:steward, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Steward.PubSub},
      # Start a worker by calling: Steward.Worker.start_link(arg)
      # {Steward.Worker, arg},
      # Start to serve requests, typically the last entry
      StewardWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Steward.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    StewardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
