defmodule Cinder.PollerSupervisor do
  @moduledoc """
  Isolates the household's 16 background workers (`Cinder.Application.poller_child/0`: search
  pollers, refreshers, sweeps, the janitor, etc.) from core infrastructure under their own
  `:one_for_one` supervisor, nested as a single child of `Cinder.Supervisor`.

  Before this, the 16 workers were flat siblings of `Cinder.Repo` and `CinderWeb.Endpoint`
  directly under `Cinder.Supervisor`'s default restart budget (3 restarts / 5 seconds, shared by
  every child). Each poller's per-tick body is wrapped in its own `isolate/2` rescue, but the
  `init/1` -> `handle_continue(:schedule, state)` path that runs immediately on every (re)start is
  not — a bad `interval` value (e.g. non-integer or negative, from a malformed
  `config :cinder, <PollerModule>, interval: ...`) crash-loops with essentially no delay between
  restarts, so it can exhaust that shared budget and take `Cinder.Supervisor` itself down —
  along with the web endpoint and DB connection pool — over one misbehaving background feature
  (#456).

  With this supervisor in between, a crash-looping worker can only exhaust *this* supervisor's
  own budget. When it does, only `Cinder.PollerSupervisor` itself terminates and is restarted —
  as a single child — by `Cinder.Supervisor`, which never sees any of the 16 workers directly and
  is unaffected either way. `max_restarts: 16` (default `max_seconds: 5`) is sized to the child
  count: one independent restart allowance per worker within the window, comfortably covering
  ordinary transient restarts across all 16 without being so high that a genuine crash loop takes
  meaningfully longer to isolate than the previous shared budget did to bring the whole app down.
  """
  use Supervisor

  @doc "`children` is `Cinder.Application.poller_child/0`'s result (`[]` when `:start_poller` is disabled)."
  def start_link(children) do
    Supervisor.start_link(__MODULE__, children, name: __MODULE__)
  end

  @impl true
  def init(children) do
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 16, max_seconds: 5)
  end
end
