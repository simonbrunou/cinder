defmodule Cinder.Accounts.PasskeyChallenges do
  @moduledoc """
  The server-side store of passkey challenges, so that each challenge is single-use and expires.

  A ceremony stores its `%Wax.Challenge{}` under a purpose (`{:sign_in, user_id}`, with `nil`
  for a signed-out visitor, or `{:register, user_id}`) and gets back an opaque random handle.
  Only the handle leaves the server's memory, held in the browser's signed session (sign-in) or
  in the hook's own JavaScript (registration); the challenge bytes reach the browser only inside
  the WebAuthn options.

  `take/2` removes the entry in one atomic `:ets.take/2`, whatever the outcome, so a handle
  answers at most once even under concurrent requests. It refuses an entry past its expiry
  (`{:error, :expired}`) and one stored for another purpose (`{:error, :wrong_purpose}`): a
  sign-in handle never completes a registration, and one user's registration never completes
  another's.

  Bounds: an entry lives `ttl_ms/0` (the `:passkey_challenge_ttl_ms` app env, 3 minutes by
  default), and a sweep drops expired entries every minute. Each class of purpose has its own
  cap, `max_entries/1`: 10,000 sign-in entries (about 1.3 KB each) and 1,000 registration
  entries, so signed-out visitors filling the sign-in pool leave registration room. When a
  class is full after dropping the expired entries, `put/2` answers `{:error, :full}`. `put/2`
  runs in the GenServer, so its count and its insert are one step and racing puts cannot pass a
  cap; `take/2` reads the table directly.

  The cap bounds memory, not who gets a challenge: clients on enough networks can still fill the
  sign-in pool. `Cinder.Accounts.IpRateLimiter`'s `:passkey_options` bucket allows each network
  10 requests in each fixed 1-minute window. An entry lives 3 minutes, so it can overlap the
  end of one window and three more: a network holds at most 40 live entries, and filling 10,000
  takes at least 250 networks.

  Unlike `Cinder.Accounts.IpRateLimiter`, the store fails closed: when its process or table is
  gone, `put/2` and `take/2` answer `{:error, :unavailable}`, and no ceremony completes. A
  limiter outage only lifts a throttle; a store outage that let a ceremony through would skip
  the single-use check.
  """
  use GenServer

  @table :cinder_passkey_challenges
  @default_max_entries %{sign_in: 10_000, register: 1_000}
  @default_ttl_ms 180_000
  @sweep_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "How long a stored challenge stays valid, in milliseconds."
  def ttl_ms, do: Application.get_env(:cinder, :passkey_challenge_ttl_ms, @default_ttl_ms)

  @doc """
  The most entries the store holds at once for a class of purpose (`:sign_in` or `:register`):
  the `:passkey_challenge_max_entries` app env, a map by class, over the defaults.
  """
  def max_entries(class) do
    @default_max_entries
    |> Map.merge(Application.get_env(:cinder, :passkey_challenge_max_entries, %{}))
    |> Map.fetch!(class)
  end

  @doc "Stores `challenge` for `purpose` and returns its handle."
  @spec put(Wax.Challenge.t(), term()) :: {:ok, String.t()} | {:error, :full | :unavailable}
  def put(%Wax.Challenge{} = challenge, purpose) do
    GenServer.call(__MODULE__, {:put, challenge, purpose, ttl_ms()})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "Removes the challenge stored under `handle` and returns it when it is fresh and for `purpose`."
  @spec take(term(), term()) ::
          {:ok, Wax.Challenge.t()}
          | {:error, :unknown | :expired | :wrong_purpose | :unavailable}
  def take(handle, purpose) when is_binary(handle) do
    case :ets.take(@table, handle) do
      [] -> {:error, :unknown}
      [{_, ^purpose, challenge, expires_at}] -> fresh(challenge, expires_at)
      [_] -> {:error, :wrong_purpose}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  def take(_handle, _purpose), do: {:error, :unknown}

  @doc "Removes the entry stored under `handle`, if any, without returning it."
  @spec discard(term()) :: :ok
  def discard(handle) when is_binary(handle) do
    :ets.delete(@table, handle)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def discard(_handle), do: :ok

  defp fresh(challenge, expires_at) do
    if now() < expires_at, do: {:ok, challenge}, else: {:error, :expired}
  end

  defp room?(class) do
    max = max_entries(class)

    if count(class) < max do
      true
    else
      sweep()
      count(class) < max
    end
  end

  # Any purpose other than a registration counts as a sign-in.
  defp class({:register, _user_id}), do: :register
  defp class(_purpose), do: :sign_in

  defp count(:register),
    do: :ets.select_count(@table, [{{:_, {:register, :_}, :_, :_}, [], [true]}])

  defp count(:sign_in), do: :ets.info(@table, :size) - count(:register)

  defp sweep do
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:"=<", :"$1", now()}], [true]}])
  end

  defp now, do: System.monotonic_time(:millisecond)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: false])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, challenge, purpose, ttl_ms}, _from, state) do
    reply =
      if room?(class(purpose)) do
        handle = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        true = :ets.insert_new(@table, {handle, purpose, challenge, now() + ttl_ms})
        {:ok, handle}
      else
        {:error, :full}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
