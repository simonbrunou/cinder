defmodule Cinder.Accounts.LoginRateLimiter do
  @moduledoc """
  Bounded online brute-force guard for password login: at most `@limit` failed attempts
  per `{ip, email}` per `@window_ms` window (a counter plus its window start; the window
  resets once the first failure in it ages out). A blocked attempt gets the same generic
  "Invalid email or password" response as bad credentials, so the limiter adds no
  enumeration or lockout oracle. bcrypt still slows each counted guess; this closes the
  sustained-run hole on public-facing deployments.

  ponytail: a public ETS counter table + periodic sweep, not a rate-limiting dep —
  single-node by design (the SQLite ceiling), household scale. Reads/writes go straight
  to ETS; the GenServer only owns the table and the sweep. The read-then-insert bump can
  lose a concurrent increment — harmless here (it can only undercount by the race width).
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
  end

  @doc "Records a failed password attempt (opens or extends the pair's window)."
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
  end

  @doc "Clears the pair on a successful login."
  def clear(ip, email) do
    :ets.delete(@table, key(ip, email))
    :ok
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
