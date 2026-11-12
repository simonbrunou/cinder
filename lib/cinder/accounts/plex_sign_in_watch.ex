defmodule Cinder.Accounts.PlexSignInWatch do
  @moduledoc """
  Runs the `plex_signin` health check (`Cinder.Accounts.PlexAuth.SignInProbe`) on a schedule and
  tells the admins when it starts failing and when it passes again. On 2026-11-05 plex.tv stopped
  listing the household server for every account Cinder holds a token for, and the admin heard
  of it from a household member (#1204).

  The first check runs about 5 minutes after boot, then one per interval, an hour by default:
  `config :cinder, #{inspect(__MODULE__)}, interval: <ms>, first_interval: <ms>`. Each tick calls
  `Cinder.Health.check/1`, so the probe keeps Health's deadline and exception handling.

  What each result sends through `Cinder.Notifier`:

    * a failure whose reason is `:server_not_listed`, `:token_rejected` or a step's
      `:unexpected_response` sends `{:health_check_failed, :plex_signin, reason}` at once;
    * any other failure (a timeout, a 5xx, a refused connection) sends it on the second failing
      tick in a row;
    * nothing more is sent while the check keeps failing;
    * the first pass after a failure it reported sends `{:health_check_recovered, :plex_signin}`;
    * `{:error, :not_configured}` sends nothing and forgets any failure, so the next failure
      counts from zero.

  The reason sent is `SignInProbe.reason/1` of the check's, a closed set of atoms, step names and
  status codes: an exception or exit from deep in the HTTP stack can hold the request, and its
  `x-plex-token` header with it.

  The state lives in this process only. After a restart during an outage, the worker reports the
  failure once more; prod redeploys on every merge and nightly, and that repeat is accepted.
  `:start_poller`-gated like the other workers, so the suite never runs it on its own.
  """
  use GenServer

  alias Cinder.Accounts.PlexAuth.SignInProbe
  alias Cinder.Health
  alias Cinder.Notifier

  @target "plex_signin"
  @event_target :plex_signin
  @default_interval :timer.hours(1)
  @default_first_interval :timer.minutes(5)

  # `failure` is `nil` (passing), `{:pending, reason}` (one failure not reported yet) or
  # `{:reported, reason}`.
  @enforce_keys [:interval]
  defstruct [:interval, failure: nil]

  @type t :: %__MODULE__{
          interval: pos_integer(),
          failure: nil | {:pending, term()} | {:reported, term()}
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs one check synchronously (tests). The scheduled path is asynchronous."
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, :infinity)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, config(:interval, @default_interval))
    first = Keyword.get(opts, :first_interval, config(:first_interval, @default_first_interval))
    schedule(first)
    {:ok, %__MODULE__{interval: interval}}
  end

  @impl true
  def handle_info(:poll, state) do
    state = check(state)
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:poll, _from, state), do: {:reply, :ok, check(state)}

  defp check(state) do
    {events, failure} = advance(state.failure, Health.check(@target))
    Enum.each(events, &Notifier.notify/1)
    %{state | failure: failure}
  end

  defp advance(_failure, {:error, :not_configured}), do: {[], nil}
  defp advance({:reported, _reason}, :ok), do: {[{:health_check_recovered, @event_target}], nil}
  defp advance(_failure, :ok), do: {[], nil}
  defp advance({:reported, _reason} = failure, {:error, _reason2}), do: {[], failure}

  defp advance(failure, {:error, reason}) do
    reason = SignInProbe.reason(reason)

    if at_once?(reason) or match?({:pending, _}, failure),
      do: {[{:health_check_failed, @event_target, reason}], {:reported, reason}},
      else: {[], {:pending, reason}}
  end

  # The probe returns no warning today; one would not be a failure.
  defp advance(failure, {:warning, _warning}), do: advance(failure, :ok)

  # A refusal plex.tv or the server gave on purpose: waiting one more hour would not change it.
  defp at_once?(:server_not_listed), do: true
  defp at_once?(:token_rejected), do: true
  defp at_once?({_step, :unexpected_response}), do: true
  defp at_once?(_reason), do: false

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)

  defp config(key, default),
    do: :cinder |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
