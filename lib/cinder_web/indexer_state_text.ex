defmodule CinderWeb.IndexerStateText do
  @moduledoc """
  The words for a native indexer's state (`Cinder.Acquisition.IndexerSource.Native.IndexerState`,
  #1657, #1619 point 13): the detail line of its dashboard row, the source row's reasons, and the
  cause of a failure. Times show in the household's time zone through
  `CinderWeb.LiveHelpers.household_time_parts/2`, with the date when not today, and a wait shows
  beside its time ("in 25 min").

  `detail/2` and `indexers/3` take `now`, the instant the state was judged at, which the health
  reasons and the dashboard's per-indexer rows carry (`Cinder.Health.check_all/0`), so the date
  and the wait count from the same instant as the state. `cause/1` words a failure reason alone.
  """
  use Gettext, backend: CinderWeb.Gettext

  alias CinderWeb.LiveHelpers

  @doc "The detail line of an indexer in `state`, judged at `now`."
  @spec detail(term(), DateTime.t()) :: String.t()
  def detail(state, now)

  def detail({:usable, at}, now),
    do: gettext("Last answered %{at}", at: at_phrase(at, now))

  def detail(:never_checked, _now), do: gettext("Not checked yet: press Test in Settings")

  def detail({:failure_backoff, until, last_failure, failures}, now),
    do:
      gettext("Backing off %{until} (%{wait}): %{cause}, %{failures}",
        until: until_phrase(until, now),
        wait: wait(until, now),
        cause: cause(last_failure),
        failures: failures(failures)
      )

  def detail({:retry_due, ended_at, :limit, 0}, now),
    do: gettext("Limit ended %{at}: the next search asks it again", at: at_phrase(ended_at, now))

  # A limit records `:limit` as the last failure but leaves the failures in a row alone, so a
  # limit that ended after failures names neither as the other.
  def detail({:retry_due, ended_at, :limit, failures}, now),
    do:
      gettext("Limit ended %{at}, after %{failures}: the next search asks it again",
        at: at_phrase(ended_at, now),
        failures: failures(failures)
      )

  def detail({:retry_due, ended_at, last_failure, failures}, now),
    do:
      gettext("Backoff ended %{at}: %{cause}, %{failures}. The next search asks it again",
        at: at_phrase(ended_at, now),
        cause: cause(last_failure),
        failures: failures(failures)
      )

  def detail({:limit_backoff, until}, now),
    do:
      gettext("Limit reached: searching again %{at} (%{wait})",
        at: at_phrase(until, now),
        wait: wait(until, now)
      )

  def detail({:credentials_rejected, {:code, code}}, _now),
    do: gettext("API key rejected (code %{code}): update it in Settings", code: code)

  def detail({:credentials_rejected, {:http_status, status}}, _now),
    do: gettext("API key rejected (HTTP %{status}): update it in Settings", status: status)

  def detail({:credentials_rejected, _by}, _now),
    do: gettext("API key rejected: update it in Settings")

  def detail({:not_supported, feature}, _now),
    do: gettext("Not supported: %{feature}", feature: feature(feature))

  def detail(:undecryptable, _now), do: gettext("Credentials can't be decrypted: re-enter them")
  def detail(:disabled, _now), do: gettext("Disabled")

  @doc """
  The source row's reason for `{:native_indexers, listed, more, now}`: each listed indexer's
  name, never translated, with its detail, then "and N more", joined through gettext.
  """
  @spec indexers(list(), non_neg_integer(), DateTime.t()) :: String.t()
  def indexers(listed, more, now) do
    lines =
      Enum.map(listed, fn %{name: name, state: state} ->
        gettext("%{name}: %{detail}", name: name, detail: detail(state, now))
      end)

    lines =
      if more > 0,
        do: lines ++ [ngettext("and %{count} more", "and %{count} more", more)],
        else: lines

    join(lines)
  end

  defp join([]), do: ""

  defp join([first | rest]),
    do: Enum.reduce(rest, first, &gettext("%{earlier}; %{next}", earlier: &2, next: &1))

  @doc "The cause of a failure reason the status table records, worded short."
  @spec cause(term()) :: String.t()
  def cause(:timeout), do: gettext("Timed out")
  def cause(:dns), do: gettext("Host not found")
  def cause(:connection_refused), do: gettext("Connection refused")
  def cause(:connection_failed), do: gettext("Connection failed")
  def cause(:bad_response), do: gettext("The answer could not be read")
  def cause(:too_large), do: gettext("The answer was too large")
  def cause(:challenge), do: gettext("Blocked by a challenge page")
  def cause(:crashed), do: gettext("The search crashed")
  def cause(:rejected_credentials), do: gettext("API key rejected")
  def cause(:limit), do: gettext("Limit reached")
  def cause({:http_status, 410}), do: gettext("Disabled in Prowlarr")
  def cause({:http_status, 404}), do: gettext("Not found in Prowlarr")
  def cause({:http_status, status}), do: gettext("HTTP %{status}", status: status)
  def cause({:indexer_error, code}), do: gettext("Indexer error %{code}", code: code)
  def cause({:query_error, code}), do: gettext("Query refused (code %{code})", code: code)
  def cause(_other), do: gettext("Failed")

  defp failures(count),
    do: ngettext("%{count} failure in a row", "%{count} failures in a row", count)

  defp feature(:flaresolverr), do: "FlareSolverr"
  defp feature(:newznab), do: "Newznab"
  defp feature(:torznab), do: "Torznab"
  defp feature(:cardigann), do: "Cardigann"
  defp feature(feature) when is_atom(feature), do: Atom.to_string(feature)
  defp feature(feature), do: inspect(feature)

  # "at 14:35", or "on Nov 27 at 14:35" when the instant falls on another household day.
  defp at_phrase(datetime, now) do
    case LiveHelpers.household_time_parts(datetime, now) do
      {nil, time} -> gettext("at %{time}", time: time)
      {date, time} -> gettext("on %{date} at %{time}", date: date, time: time)
    end
  end

  # "until 14:35", or "until Nov 27 at 14:35".
  defp until_phrase(datetime, now) do
    case LiveHelpers.household_time_parts(datetime, now) do
      {nil, time} -> gettext("until %{time}", time: time)
      {date, time} -> gettext("until %{date} at %{time}", date: date, time: time)
    end
  end

  # How long until `until`: "in 25 min", "in 1 h 52 min", "in 2 h"; a time already past reads as
  # under a minute.
  defp wait(until, now) do
    minutes = div(max(DateTime.diff(until, now, :second), 0), 60)

    cond do
      minutes < 1 ->
        gettext("in under a minute")

      minutes < 60 ->
        gettext("in %{minutes} min", minutes: minutes)

      rem(minutes, 60) == 0 ->
        gettext("in %{hours} h", hours: div(minutes, 60))

      true ->
        gettext("in %{hours} h %{minutes} min",
          hours: div(minutes, 60),
          minutes: rem(minutes, 60)
        )
    end
  end
end
