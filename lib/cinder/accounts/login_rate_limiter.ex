defmodule Cinder.Accounts.LoginRateLimiter do
  @moduledoc """
  Bounded online brute-force guard for password login: at most `@limit` failed attempts
  per `{ip, email}` per `@window_ms` window (a counter plus its window start; the window
  resets once the first failure in it ages out). A blocked attempt gets the same generic
  "Invalid email or password" response as bad credentials, so the limiter adds no
  enumeration or lockout oracle. bcrypt still slows each counted guess; this closes the
  sustained-run hole on public-facing deployments.

  Deployment ceiling (accepted at household scale): behind the documented reverse proxy,
  `conn.remote_ip` is the proxy for every client, so the key degrades to effectively
  per-email — an anonymous visitor can lock a known email's password login for a window
  with 10 junk attempts (a targeted-lockout DoS, though never an enumeration oracle).
  Trusting x-forwarded-for WITHOUT a configured trusted-proxy list would be worse (a
  spoofed header per request bypasses the limiter entirely); the upgrade path if this
  ever matters is a trusted-proxy remote_ip rewrite (e.g. the `remote_ip` package).

  ponytail: a public ETS counter table + periodic sweep, not a rate-limiting dep —
  single-node by design (the SQLite ceiling), household scale. Reads/writes go straight
  to ETS; the GenServer only owns the table and the sweep. The read-then-insert bump can
  lose a concurrent increment — harmless here (it can only undercount by the race width).
  Every public call fails OPEN if the table is briefly gone (a limiter restart must not
  turn logins into 500s).
  """
  use GenServer

  @table :cinder_login_attempts
  @limit 10
  @window_ms 15 * 60 * 1000
  @sweep_ms @window_ms

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "True when this `{ip, email}` pair has exhausted its failed-attempt budget."
  def blocked?(ip, email) do
    case :ets.lookup(@table, key(ip, email)) do
      [{_key, count, started}] -> count >= @limit and now() - started < @window_ms
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc """
  Records a failed password attempt. The window is FIXED, anchored at the pair's first
  failure — later failures increment the counter but never extend it; once it ages out
  the next failure opens a fresh one.
  """
  def register_failure(ip, email) do
    key = key(ip, email)

    case :ets.lookup(@table, key) do
      [{^key, count, started}] ->
        if now() - started < @window_ms,
          do: :ets.insert(@table, {key, count + 1, started}),
          else: :ets.insert(@table, {key, 1, now()})

      [] ->
        :ets.insert(@table, {key, 1, now()})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Clears the pair — on a successful login or an authenticated password change."
  def clear(ip, email) do
    :ets.delete(@table, key(ip, email))
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Empties the table — test isolation only."
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp key(ip, email), do: {ip, String.downcase(email)}
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

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
