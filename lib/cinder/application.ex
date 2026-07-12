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
        # Owns cancellable outbound HTTP requests so wall-clock deadlines never link-crash callers.
        {Task.Supervisor, name: Cinder.HTTPPolicy.TaskSupervisor},
        # Off-process, best-effort subtitle fetches dispatched from the import path — supervised so
        # they don't run in (and can't stall) the poller tick. Always on; inert when subtitles off.
        {Task.Supervisor, name: Cinder.Subtitles.TaskSupervisor},
        # Vault before the loader (it decrypts secret settings); the loader applies the
        # DB settings overlay synchronously, before the Endpoint/poller consume config.
        Cinder.Vault,
        Cinder.Settings,
        # Owns the login-attempt ETS table; must be up before the Endpoint serves logins.
        Cinder.Accounts.LoginRateLimiter,
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
      blank_env?("CINDER_BASIC_AUTH_USER") and blank_env?("CINDER_BASIC_AUTH_PASSWORD")

    no_basic_auth? and Cinder.Repo.aggregate(Cinder.Accounts.User, :count) == 0
  end

  # Matches the router's `present/1`: a nil or blank/whitespace value counts as unset.
  defp blank_env?(key) do
    case System.get_env(key) do
      nil -> true
      val -> String.trim(val) == ""
    end
  end

  defp warn_if_unprotected do
    if unprotected_fresh_instance?() do
      require Logger

      Logger.warning(
        "Cinder has no accounts and no CINDER_BASIC_AUTH_* gate set. First registration requires " <>
          "CINDER_BOOTSTRAP_TOKEN and remains unavailable while it is unset. Keep the token private " <>
          "and put the instance behind a reverse-proxy/VPN until you create your admin."
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
      [
        Cinder.Download.Poller,
        Cinder.Download.TvPoller,
        Cinder.Catalog.Refresher,
        Cinder.Subtitles.Sweeper
      ]
    else
      []
    end
  end
end
