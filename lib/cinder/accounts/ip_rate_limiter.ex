defmodule Cinder.Accounts.IpRateLimiter do
  @moduledoc """
  Bounded fixed-window throttle for the auth surface: one shared ETS counter table keyed
  `{bucket, id}`, at most `@limit` attempts per key per bucket window (a counter plus its
  window start). The window is FIXED, anchored at the key's first attempt — later attempts
  increment the counter but never extend it; once it ages out the next attempt opens a
  fresh one. Buckets:

    * `:login_pair` — online brute-force guard for password login, keyed on
      `{ip, downcased_email}` (callers build the pair), 15-minute window. A blocked
      attempt gets the same generic "Invalid email or password" response as bad
      credentials, so the limiter adds no enumeration or lockout oracle; bcrypt still
      slows each counted guess.
    * `:login` — an IP-only floor beneath the pair guard that a rotated-email attacker
      can't evade by changing the one thing the pair keys on, 1-minute window.
    * `:registration` — IP-keyed (no account exists yet, so there is no per-account key),
      1-minute window.

  The IP-only buckets are config-gated via `Application.get_env(:cinder,
  :ip_rate_limiting, true)` (default ON; `config/test.exs` defaults it OFF) because every
  `ConnCase`/`LiveViewTest` request shares the same test-harness peer address — an
  always-on global IP bucket would let unrelated tests exhaust each other's budget. Tests
  that exercise those buckets flip the flag on locally and restore it in `on_exit`,
  matching the existing `secure_cookies` toggle pattern. `:login_pair` has a different
  per-bucket default: always on, flag ignored — its keys carry the email, so tests never
  trample each other.

  Only the race-safe API lives here: `check_and_register/2` (one atomic
  increment-and-check), `clear/2`, `reset/0`. A separate blocked?/register pair leaves the
  check-then-act race open under a burst — many callers all read "not blocked" before any
  increment lands.

  Deployment ceiling (see `Cinder.HTTPPolicy`'s "critical deployment dependency" and the
  pre-exposure security audit's finding 2): behind cloudflared without
  `CinderWeb.Plugs.RemoteIp` resolving a real client IP, every IP-keyed bucket collapses
  to one shared key for the whole internet — the throttle then bounds total worst-case
  bcrypt CPU cost rather than any one visitor's — and `:login_pair` degrades to
  effectively per-email: an anonymous visitor can lock a known email's password login for
  a window with 10 junk attempts (a targeted-lockout DoS, though never an enumeration
  oracle). Trusting x-forwarded-for WITHOUT a configured trusted-proxy list would be worse
  (a spoofed header per request bypasses the limiter entirely).

  ponytail: a public ETS counter table + periodic sweep, not a rate-limiting dep —
  single-node by design (the SQLite ceiling), household scale. Reads/writes go straight
  to ETS; the GenServer only owns the table and the sweep. Every public call fails OPEN
  if the table is briefly gone (a limiter restart must not turn logins/registrations
  into 500s).
  """
  use GenServer

  @table :cinder_ip_attempts
  @limit 10
  @window_ms %{login_pair: 15 * 60 * 1000, login: 60_000, registration: 60_000}
  @sweep_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Atomically records an attempt and reports whether `bucket`/`id` is now over budget.

  The increment is a single atomic `:ets.update_counter/4`, so N concurrent callers each get a
  distinct count and everything past `@limit` reports `:blocked`. Returns `:ok` while under
  budget (or while the bucket is disabled), `:blocked` once over.
  """
  def check_and_register(bucket, id) do
    if enabled?(bucket) do
      if do_register(bucket, id) > @limit, do: :blocked, else: :ok
    else
      :ok
    end
  rescue
    ArgumentError -> :ok
  end

  # Resets the window via select_replace if it has expired, then atomically bumps and returns the
  # new count (creating the row at 1 on first hit).
  defp do_register(bucket, id) do
    key = {bucket, id}
    timestamp = now()
    cutoff = timestamp - Map.fetch!(@window_ms, bucket)

    :ets.select_replace(@table, [
      {{:"$1", :_, :"$2"}, [{:==, :"$1", {:const, key}}, {:"=<", :"$2", cutoff}],
       [{{:"$1", 0, timestamp}}]}
    ])

    :ets.update_counter(@table, key, {2, 1}, {key, 0, timestamp})
  end

  @doc "Clears `bucket`/`id` — for an authenticated action that already proved possession."
  def clear(bucket, id) do
    :ets.delete(@table, {bucket, id})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Empties the table — test isolation only."
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  # Per-bucket default for the test flag: :login_pair is always on (see @moduledoc), the
  # IP-only buckets honor :ip_rate_limiting.
  defp enabled?(:login_pair), do: true
  defp enabled?(_bucket), do: Application.get_env(:cinder, :ip_rate_limiting, true)

  defp now, do: System.monotonic_time(:millisecond)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    timestamp = now()

    Enum.each(@window_ms, fn {bucket, window_ms} ->
      cutoff = timestamp - window_ms
      :ets.select_delete(@table, [{{{bucket, :_}, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    end)

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
