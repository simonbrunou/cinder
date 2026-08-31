defmodule Cinder.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        # Serializes bounded `df` ports and holds the circuit open if SIGKILL cannot reap one.
        Cinder.Disk.CommandProbe,
        CinderWeb.Telemetry,
        Cinder.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:cinder, :ecto_repos),
         skip: skip_migrations?(),
         migrator: &run_migrations/3},
        {Phoenix.PubSub, name: Cinder.PubSub},
        # Owns cancellable outbound HTTP requests so wall-clock deadlines never link-crash callers.
        {Task.Supervisor, name: Cinder.HTTPPolicy.TaskSupervisor},
        # Owns notifier deliveries so a slow transport (e.g. SMTP) runs off the emitting pipeline's
        # critical path instead of wedging a poller tick (Cinder.Notifier.Dispatcher).
        {Task.Supervisor, name: Cinder.Notifier.TaskSupervisor},
        # Off-tick, best-effort subtitle fetches dispatched from the import path — serialized through
        # one process so a bulk import can't burst OpenSubtitles into rate-limiting it (issue #80).
        # Always on; inert when subtitles off.
        Cinder.Subtitles.Fetcher,
        # Vault before the loader (it decrypts secret settings); the loader applies the
        # DB settings overlay synchronously, before the Endpoint/poller consume config.
        Cinder.Vault,
        Cinder.Settings,
        # Owns the auth rate-limit ETS table (the {ip, email} login guard plus the IP-only
        # registration and login floors); must be up before the Endpoint serves logins.
        Cinder.Accounts.IpRateLimiter,
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

  # The default `Ecto.Migrator` supervised migrator; wrapped so a boot-migration failure is logged
  # loudly — naming the repo and the full exception + stacktrace (which names the failing migration
  # module) — BEFORE it propagates. Without this the raise crash-loops the supervisor with the real
  # cause buried under application-controller shutdown noise. The error is re-raised, never
  # swallowed: a bad migration must still stop the boot.
  defp run_migrations(repo, direction, opts) do
    Ecto.Migrator.run(repo, direction, opts)
  rescue
    error ->
      Logger.critical(
        "Cinder boot migration failed for #{inspect(repo)}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      reraise error, __STACKTRACE__
  end

  @doc false
  # Public only so the `:start_poller` gate is directly assertable in a test; not part of the API.
  def poller_child do
    if Application.get_env(:cinder, :start_poller, true) do
      [
        Cinder.Download.Poller,
        Cinder.Download.TvPoller,
        Cinder.Download.BookPoller,
        Cinder.Catalog.Refresher,
        Cinder.Books.Refresher,
        Cinder.Catalog.Rehunter,
        Cinder.Catalog.UpgradeHunter,
        Cinder.Download.Cleaner,
        Cinder.Subtitles.Sweeper,
        Cinder.Subtitles.Sync.Worker,
        Cinder.Library.MediaServer.Reconciler,
        Cinder.Requests.WatchlistSync,
        Cinder.Accounts.Janitor,
        Cinder.DatabaseBackup
      ]
    else
      []
    end
  end
end
