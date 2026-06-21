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
    result = Supervisor.start_link(children, opts)

    # ponytail: best-effort log, wrapped so a DB hiccup at boot can't crash start/2.
    try do
      warn_if_unprotected()
    rescue
      _ -> :ok
    end

    result
  end

  def unprotected_fresh_instance? do
    no_basic_auth? =
      is_nil(System.get_env("CINDER_BASIC_AUTH_USER")) and
        is_nil(System.get_env("CINDER_BASIC_AUTH_PASSWORD"))

    no_basic_auth? and Cinder.Repo.aggregate(Cinder.Accounts.User, :count) == 0
  end

  defp warn_if_unprotected do
    if unprotected_fresh_instance?() do
      require Logger

      Logger.warning(
        "Cinder has no accounts and no CINDER_BASIC_AUTH_* gate set: registration is open to " <>
          "anyone who reaches this instance, and the first registrant becomes admin. Put it behind " <>
          "a reverse-proxy/VPN or set CINDER_BASIC_AUTH_USER/PASSWORD until you create your admin."
      )
    end
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
