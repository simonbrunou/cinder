defmodule Cinder.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        CinderWeb.Telemetry,
        Cinder.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:cinder, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:cinder, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Cinder.PubSub},
        # Vault before the loader (it decrypts secret settings); the loader applies the
        # DB settings overlay synchronously, before the Endpoint/poller consume config.
        Cinder.Vault,
        Cinder.Settings,
        CinderWeb.Endpoint
      ] ++ poller_child()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Cinder.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CinderWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations? do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  defp poller_child do
    if Application.get_env(:cinder, :start_poller, true) do
      [Cinder.Download.Poller]
    else
      []
    end
  end
end
