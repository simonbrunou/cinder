defmodule Cinder.PollerSupervisor do
  @moduledoc """
  Isolates the household's 18 background workers (`Cinder.Application.poller_child/0`: search
  pollers, refreshers, sweeps, the janitor, the indexer definitions update, etc.) from core
  infrastructure under their own `:one_for_one` supervisor.

  Before this, the 16 workers were flat siblings of `Cinder.Repo` and `CinderWeb.Endpoint`
  directly under `Cinder.Supervisor`'s default restart budget (3 restarts / 5 seconds, shared by
  every child). Each poller's per-tick body is wrapped in its own `isolate/2` rescue, but the
  `init/1` -> `handle_continue(:schedule, state)` path that runs immediately on every (re)start is
  not — a bad `interval` value (e.g. non-integer or negative, from a malformed
  `config :cinder, <PollerModule>, interval: ...`) crash-loops with essentially no delay between
  restarts, so it can exhaust that shared budget and take `Cinder.Supervisor` itself down —
  along with the web endpoint and DB connection pool — over one misbehaving background feature
  (#456).

  `max_restarts: 17` (default `max_seconds: 5`) was sized to the 17 workers this supervisor had
  before the definitions update (#1669) joined them: about one restart allowance per worker
  within the window, which still covers ordinary transient restarts.

  Nesting this alone is not enough: a *persistently* bad config value (as opposed to a transient
  blip) crash-loops again immediately on every restart, including after this supervisor's own
  budget is exceeded and `Cinder.Supervisor` restarts it — reached empirically: booting a real
  poller with a permanently invalid `interval` still took `Cinder.Repo`/`CinderWeb.Endpoint` down
  a few seconds later, because three of *this* supervisor's own restarts (each near-instant) fit
  comfortably inside `Cinder.Supervisor`'s outer 3-restarts-in-5-seconds budget. `Cinder.Supervisor`
  must therefore never attempt to restart this supervisor at all — see the `restart: :temporary`
  child-spec override where this is started (`Cinder.Application.start/2`). That makes a
  permanently crash-looping worker stop the whole poller subtree, once, for good, instead of
  cascading: `Cinder.PollerSupervisor.Watchdog` logs loudly at `:error` when that happens, since
  nothing else would otherwise notice background work has stopped.
  """
  use Supervisor

  @doc "`children` is `Cinder.Application.poller_child/0`'s result (`[]` when `:start_poller` is disabled)."
  def start_link(children) do
    Supervisor.start_link(__MODULE__, children, name: __MODULE__)
  end

  @impl true
  def init(children) do
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 17, max_seconds: 5)
  end
end
