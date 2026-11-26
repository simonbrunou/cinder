defmodule Cinder.Acquisition.IndexerSource.Native.Lease do
  @moduledoc """
  The slot lease of `Cinder.Acquisition.IndexerSource.Native` (#1655, #1619 point 8): at most one
  request at a time to each configured indexer, and the next request to it starts at least the
  spacing after the previous one ended. A supervised child of `Cinder.Application`.

  ## The rules

  - The lease is keyed by configured indexer, never by host: two configured indexers on one
    Prowlarr or Jackett host do not wait for each other.
  - The spacing is 2 s, from the end of one request to the start of the next, unless the
    `spacing_ms` key of `config :cinder, #{inspect(__MODULE__)}` sets another. A per-indexer delay
    (`run/4`'s `:delay_ms`) longer than the spacing wins for that indexer: the Cardigann adapter
    passes its definition's `requestDelay` (#1671). Each used slot emits
    `[:cinder, :native, :lease, :spaced]` with the gap it applied as `spacing_ms` and the
    indexer as `key`.
  - An `:interactive` request (a manual search or a Test) is granted before every `:background`
    one waiting for the same indexer, and requests of one class are granted in the order they
    came. A request already running is never cut.
  - The process that runs `run/4` holds the slot while its function runs, so it sends the request
    and records the answer in `Cinder.Acquisition.IndexerSource.Native.IndexerStatus` before the
    slot frees. A holder that dies frees the slot, and the spacing still counts from its death.
  - A request still waiting at its `:deadline_at` never runs.
  - After the grant, `run/4` asks its `:gate` whether the request may still go out, since an
    answer recorded while it waited can have started a backoff. A gate that says no frees the
    slot with the spacing left as it was, since nothing was sent.
  - A lease process that is not running, or dies while a request waits, answers that request as
    never started.

  An indexer that holds no slot and has no request waiting once its spacing has passed leaves the
  lease's state.

  `start_link/1` takes `name:` (`#{inspect(__MODULE__)}` by default, `nil` for none), `clock:`, a
  0-arity function answering the time in milliseconds (`System.monotonic_time(:millisecond)` by
  default), and `config:`, a 0-arity function answering the keyword list the spacing is read
  from, at each release (the app env above by default). A test starts its own instance with
  both.
  """
  use GenServer

  require Logger

  @spacing_ms 2_000

  @type priority :: :interactive | :background
  @type outcome :: Cinder.Acquisition.IndexerSource.Report.outcome()

  @never_started {:not_run, {:skipped, :deadline}}

  @doc "Starts the lease; see the moduledoc for the options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Runs `fun` while holding the slot of the indexer `key` on `lease`, and answers `{:ran, value}`
  with its value. Answers `{:not_run, outcome}` with `fun` never called:

  - `{:skipped, :deadline}` when the slot was not granted before `opts[:deadline_at]`, or the
    lease is not running or died first: the request never started.
  - the gate's answer when `opts[:gate]` answers anything but `:ask` once the slot is granted.

  `opts`: `:deadline_at` (required, `System.monotonic_time(:millisecond)`), `:priority`
  (`:background` by default), `:delay_ms` (the indexer's own delay, none by default) and `:gate`
  (a 0-arity function, `:ask` by default). A raise in `fun` frees the slot and goes on to the
  caller.
  """
  @spec run(GenServer.server(), term(), keyword(), (-> value)) ::
          {:ran, value} | {:not_run, outcome()}
        when value: term()
  def run(lease \\ __MODULE__, key, opts, fun) do
    deadline_at = Keyword.fetch!(opts, :deadline_at)

    case GenServer.whereis(lease) do
      pid when is_pid(pid) ->
        monitor = Process.monitor(pid)
        ref = make_ref()
        priority = Keyword.get(opts, :priority, :background)
        delay_ms = Keyword.get(opts, :delay_ms, 0)
        GenServer.cast(pid, {:acquire, key, priority, self(), ref, delay_ms})

        answer = await_grant(pid, monitor, key, ref, deadline_at, opts, fun)
        Process.demonitor(monitor, [:flush])
        answer

      _not_running ->
        lease_gone(key)
    end
  end

  defp await_grant(pid, monitor, key, ref, deadline_at, opts, fun) do
    left_ms = max(deadline_at - System.monotonic_time(:millisecond), 0)

    receive do
      {__MODULE__, ^ref, :granted} -> holding(pid, key, ref, deadline_at, opts, fun)
      {:DOWN, ^monitor, :process, _pid, _reason} -> lease_gone(key)
    after
      left_ms -> cancel(pid, key, ref)
    end
  end

  # The grant came. One that came at the deadline sends nothing either.
  defp holding(pid, key, ref, deadline_at, opts, fun) do
    if System.monotonic_time(:millisecond) >= deadline_at do
      release(pid, key, ref, :unused)
      @never_started
    else
      gated(pid, key, ref, Keyword.get(opts, :gate, fn -> :ask end).(), fun)
    end
  end

  defp gated(pid, key, ref, :ask, fun) do
    {:ran, fun.()}
  after
    release(pid, key, ref, :used)
  end

  defp gated(pid, key, ref, outcome, _fun) do
    release(pid, key, ref, :unused)
    {:not_run, outcome}
  end

  # The deadline came first. The lease may have granted the slot meanwhile: then it frees it,
  # and the grant left in the mailbox is dropped.
  defp cancel(pid, key, ref) do
    case GenServer.call(pid, {:cancel, key, ref}) do
      :granted ->
        receive do
          {__MODULE__, ^ref, :granted} -> :ok
        after
          0 -> :ok
        end

      :cancelled ->
        :ok
    end

    @never_started
  catch
    :exit, _reason -> lease_gone(key)
  end

  # A call, so the slot is free once `run/4` returns.
  defp release(pid, key, ref, use) do
    GenServer.call(pid, {:release, key, ref, use})
  catch
    :exit, _reason -> :ok
  end

  defp lease_gone(key) do
    Logger.warning("native indexer lease is down; request to indexer #{inspect(key)} not sent")
    @never_started
  end

  # --- the server ---

  @impl true
  def init(opts) do
    {:ok,
     %{
       indexers: %{},
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
       config: Keyword.get(opts, :config, fn -> Application.get_env(:cinder, __MODULE__, []) end)
     }}
  end

  @impl true
  def handle_cast({:acquire, key, priority, pid, ref, delay_ms}, state) do
    waiter = {pid, ref, Process.monitor(pid), delay_ms}
    queue = if priority == :interactive, do: :interactive, else: :background

    state
    |> update_entry(key, fn entry -> Map.update!(entry, queue, &:queue.in(waiter, &1)) end)
    |> advance(key)
    |> noreply()
  end

  @impl true
  def handle_call({:release, key, ref, use}, _from, state) do
    case state.indexers do
      %{^key => %{holder: {_pid, ^ref, monitor, delay_ms}}} ->
        Process.demonitor(monitor, [:flush])
        {:reply, :ok, state |> free(key, use, delay_ms) |> advance(key)}

      _other ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:cancel, key, ref}, _from, state) do
    case state.indexers do
      %{^key => %{holder: {_pid, ^ref, monitor, delay_ms}}} ->
        Process.demonitor(monitor, [:flush])
        {:reply, :granted, state |> free(key, :unused, delay_ms) |> advance(key)}

      %{^key => _entry} ->
        {:reply, :cancelled,
         state |> drop_waiter(key, &match?({_pid, ^ref, _mon, _delay}, &1)) |> advance(key)}

      _other ->
        {:reply, :cancelled, state}
    end
  end

  @impl true
  def handle_info({:check, key}, state), do: state |> advance(key) |> noreply()

  def handle_info(:check, state),
    do: state.indexers |> Map.keys() |> Enum.reduce(state, &advance(&2, &1)) |> noreply()

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    state.indexers
    |> Enum.find_value(fn {key, entry} -> if holder_monitor?(entry, monitor), do: key end)
    |> case do
      nil ->
        state.indexers
        |> Map.keys()
        |> Enum.reduce(state, fn key, state ->
          state |> drop_waiter(key, &match?({_pid, _ref, ^monitor, _delay}, &1)) |> advance(key)
        end)

      key ->
        {_pid, _ref, _monitor, delay_ms} = state.indexers[key].holder
        state |> free(key, :used, delay_ms) |> advance(key)
    end
    |> noreply()
  end

  defp holder_monitor?(%{holder: {_pid, _ref, monitor, _delay}}, monitor), do: true
  defp holder_monitor?(_entry, _monitor), do: false

  defp noreply(state), do: {:noreply, state}

  defp new_entry,
    do: %{holder: nil, free_at: nil, interactive: :queue.new(), background: :queue.new()}

  defp update_entry(state, key, fun) do
    entry = Map.get(state.indexers, key, new_entry())
    %{state | indexers: Map.put(state.indexers, key, fun.(entry))}
  end

  # A used slot frees the next start the spacing, or the indexer's longer delay, from now. An
  # unused one leaves the next start as it was. `[:cinder, :native, :lease, :spaced]` carries the
  # gap a used slot applied, so a test reads the spacing with no sleep.
  defp free(state, key, :used, delay_ms) do
    spacing_ms = max(Keyword.get(state.config.(), :spacing_ms, @spacing_ms), delay_ms)

    :telemetry.execute([:cinder, :native, :lease, :spaced], %{spacing_ms: spacing_ms}, %{key: key})

    update_entry(state, key, &%{&1 | holder: nil, free_at: state.clock.() + spacing_ms})
  end

  defp free(state, key, :unused, _delay_ms), do: update_entry(state, key, &%{&1 | holder: nil})

  defp drop_waiter(state, key, match?) do
    update_entry(state, key, fn entry ->
      for {_pid, _ref, monitor, _delay} = waiter <- waiters(entry),
          match?.(waiter),
          do: Process.demonitor(monitor, [:flush])

      %{
        entry
        | interactive: :queue.filter(&(not match?.(&1)), entry.interactive),
          background: :queue.filter(&(not match?.(&1)), entry.background)
      }
    end)
  end

  defp waiters(entry), do: :queue.to_list(entry.interactive) ++ :queue.to_list(entry.background)

  # Grants the slot of `key` to the next waiter, interactive first, once it is free and its
  # spacing has passed; else sets a timer for the spacing's end. Drops an idle entry.
  defp advance(state, key) do
    case Map.fetch(state.indexers, key) do
      {:ok, %{holder: nil} = entry} -> advance_free(state, key, entry, state.clock.())
      _held_or_gone -> state
    end
  end

  defp advance_free(state, key, entry, now) do
    cond do
      entry.free_at != nil and now < entry.free_at ->
        Process.send_after(self(), {:check, key}, entry.free_at - now)
        state

      not :queue.is_empty(entry.interactive) ->
        grant(state, key, entry, :interactive)

      not :queue.is_empty(entry.background) ->
        grant(state, key, entry, :background)

      true ->
        %{state | indexers: Map.delete(state.indexers, key)}
    end
  end

  defp grant(state, key, entry, queue) do
    {{:value, {pid, ref, _monitor, _delay} = waiter}, rest} = :queue.out(Map.fetch!(entry, queue))
    send(pid, {__MODULE__, ref, :granted})
    %{state | indexers: Map.put(state.indexers, key, %{entry | :holder => waiter, queue => rest})}
  end
end
