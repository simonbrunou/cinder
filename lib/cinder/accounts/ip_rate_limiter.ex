defmodule Cinder.Accounts.IpRateLimiter do
  @moduledoc """
  Bounded IP-only throttle, sibling to `LoginRateLimiter`'s `{ip, email}` guard. Two call
  sites need a budget with no natural per-account key at all: registration (no account
  exists yet) and a floor under login that a rotated-email attacker can't evade by changing
  the one thing `LoginRateLimiter` keys on. Same fixed-window ETS design as
  `LoginRateLimiter`, generalized with a `bucket` atom so each call site gets its own
  counters in one shared table.

  Config-gated via `Application.get_env(:cinder, :ip_rate_limiting, true)` (default ON;
  `config/test.exs` defaults it OFF) because every `ConnCase`/`LiveViewTest` request shares
  the same test-harness peer address — an always-on global IP bucket would let unrelated
  tests exhaust each other's budget. Tests that exercise this limiter flip the flag on
  locally and restore it in `on_exit`, matching the existing `secure_cookies` toggle pattern.

  Deployment ceiling (see `Cinder.HTTPPolicy`'s "critical deployment dependency" and the
  pre-exposure security audit's finding 2): behind cloudflared without
  `CinderWeb.Plugs.RemoteIp` resolving a real client IP, every bucket collapses to one
  shared key for the whole internet — the throttle then bounds total worst-case bcrypt CPU
  cost rather than any one visitor's, which is still the point for the registration LiveView
  (see its moduledoc for why per-visitor keying isn't available there).

  ponytail: a public ETS counter table + periodic sweep, not a rate-limiting dep — see
  `LoginRateLimiter` for the same reasoning. Every public call fails OPEN if the table is
  briefly gone (a limiter restart must not turn logins/registrations into 500s).
  """
  use GenServer

  @table :cinder_ip_attempts
  @limit 10
  @window_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "True when `bucket` (e.g. `:registration`, `:login`) has exhausted its budget for `ip`."
  def blocked?(bucket, ip) do
    if enabled?() do
      case :ets.lookup(@table, key(bucket, ip)) do
        [{_key, count, started}] -> count >= @limit and now() - started < @window_ms
        [] -> false
      end
    else
      false
    end
  rescue
    ArgumentError -> false
  end

  @doc """
  Atomically records an attempt and reports whether `bucket`/`ip` is now over budget.

  The increment is a single atomic `:ets.update_counter/4`, so N concurrent callers each get a
  distinct count and everything past `@limit` reports `:blocked`. This closes the check-then-act
  race that a separate `blocked?/2` + `register_attempt/2` pair leaves open under a burst (many
  callers all read "not blocked" before any increment lands, so a concurrent flood sails through).
  Prefer this at a rate-limit gate. Returns `:ok` while under budget (or while disabled),
  `:blocked` once over.
  """
  def check_and_register(bucket, ip) do
    if enabled?() do
      if do_register(bucket, ip) > @limit, do: :blocked, else: :ok
    else
      :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Records an attempt for `bucket`/`ip`. Fixed window anchored at the bucket's first attempt,
  same semantics as `LoginRateLimiter.register_failure/2`. A no-op while disabled, so the
  table never accumulates entries from a deployment/test run that never enables it.

  Prefer `check_and_register/2` at a gate — this leaves the check-then-act race open.
  """
  def register_attempt(bucket, ip) do
    if enabled?(), do: do_register(bucket, ip)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Resets the window via select_replace if it has expired, then atomically bumps and returns the
  # new count (creating the row at 1 on first hit).
  defp do_register(bucket, ip) do
    key = key(bucket, ip)
    timestamp = now()
    cutoff = timestamp - @window_ms

    :ets.select_replace(@table, [
      {{:"$1", :_, :"$2"}, [{:==, :"$1", {:const, key}}, {:"=<", :"$2", cutoff}],
       [{{:"$1", 0, timestamp}}]}
    ])

    :ets.update_counter(@table, key, {2, 1}, {key, 0, timestamp})
  end

  @doc "Clears `bucket`/`ip` — for an authenticated action that already proved possession."
  def clear(bucket, ip) do
    :ets.delete(@table, key(bucket, ip))
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Empties the table — test isolation only."
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp enabled?, do: Application.get_env(:cinder, :ip_rate_limiting, true)
  defp key(bucket, ip), do: {bucket, ip}
  defp now, do: System.monotonic_time(:millisecond)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now() - @window_ms
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @window_ms)
end
