defmodule Cinder.RepoWatch.Stall do
  @moduledoc """
  Ticks every second on the monotonic clock and logs `db watch: stall, tick <D> ms late` when a
  tick arrives the stall threshold or more after it was due (#1310). A late tick means this
  process could not run for that long, as when the node's CPU, memory or disk IO starves it.
  `Cinder.RepoWatch` documents every `db watch:` line and the `:start_repo_watch` gate.

  Options, for tests: `:name` (default this module; `nil` for none), `:clock` (a 0-arity function
  returning milliseconds), `:schedule` (a 1-arity function given the delay in ms, which arranges
  the next `:tick` message) and `:threshold_ms` (default the configured stall threshold).
  """

  use GenServer

  require Logger

  @interval_ms 1_000

  @enforce_keys [:clock, :schedule, :threshold]
  defstruct clock: nil, schedule: nil, threshold: nil, due: nil

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      clock: Keyword.get(opts, :clock, &Cinder.RepoWatch.monotonic_ms/0),
      schedule: Keyword.get(opts, :schedule, &schedule/1),
      threshold:
        Keyword.get_lazy(opts, :threshold_ms, fn -> Cinder.RepoWatch.thresholds().stall end)
    }

    {:ok, arm(state, state.clock.())}
  end

  @impl true
  def handle_info(:tick, state) do
    now = state.clock.()
    late = now - state.due

    if late >= state.threshold do
      Logger.warning("#{Cinder.RepoWatch.prefix()} stall, tick #{late} ms late")
    end

    {:noreply, arm(state, now)}
  end

  defp arm(%__MODULE__{} = state, now) do
    state.schedule.(@interval_ms)
    %__MODULE__{state | due: now + @interval_ms}
  end

  defp schedule(delay_ms), do: Process.send_after(self(), :tick, delay_ms)
end
