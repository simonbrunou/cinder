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

  @doc """
  The detail line of an indexer in `state`, judged at `now`, or nil for a state it does not word
  yet, such as one #1668 adds before #1676 words it.
  """
  @spec detail(term(), DateTime.t() | nil) :: String.t() | nil
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

  # A refused Cardigann login (#1680): the `cookie` method's cookie, else the username and
  # password.
  def detail({:credentials_rejected, {:login_rejected, :cookie}}, _now),
    do: gettext("Cookie rejected: paste a new one in Settings")

  def detail({:credentials_rejected, {:login_rejected, _method}}, _now),
    do: gettext("Login rejected: check the username and password in Settings")

  def detail({:credentials_rejected, _by}, _now),
    do: gettext("API key rejected: update it in Settings")

  def detail({:not_supported, feature}, _now),
    do: gettext("Not supported: %{feature}", feature: feature(feature))

  def detail(:undecryptable, _now), do: gettext("Credentials can't be decrypted: re-enter them")
  def detail(:disabled, _now), do: gettext("Disabled")
  def detail(_state, _now), do: nil

  @doc """
  The last-Test line of the indexers table in `/settings` (#1660, #1619 point 11), for a
  `last_test` (`IndexerStatus.last_test/1`) shown at `now`: "Last Test: worked at 14:07", "Last
  Test: API key rejected at 14:07", with the date when the Test ran on another household day. A
  failure reads its `cause/1`.
  """
  @spec last_test(%{outcome: term(), at: DateTime.t()}, DateTime.t()) :: String.t()
  def last_test(%{outcome: outcome, at: at}, now),
    do:
      gettext("Last Test: %{outcome} %{at}",
        outcome: test_outcome(outcome),
        at: at_phrase(at, now)
      )

  @doc """
  The words for a stored Test outcome, as `last_test/2` and the table's notice line show it:
  "worked", "limit reached", or the failure's `cause/1`.
  """
  @spec test_outcome(term()) :: String.t()
  def test_outcome(:success), do: gettext("worked")
  def test_outcome(:limit), do: gettext("limit reached")
  def test_outcome(outcome), do: cause(outcome)

  @doc """
  The source row's reason for `{:native_indexers, listed, more, now}`: each listed indexer's
  name, never translated, with its detail, then "and N more", joined through gettext. A state
  `detail/2` does not word yet shows the name alone.
  """
  @spec indexers(list(), non_neg_integer(), DateTime.t()) :: String.t()
  def indexers(listed, more, now) do
    lines =
      Enum.map(listed, fn %{name: name, state: state} ->
        case detail(state, now) do
          nil -> name
          detail -> gettext("%{name}: %{detail}", name: name, detail: detail)
        end
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
  def cause(:login_rejected), do: gettext("Login rejected")
  def cause(:cookie_rejected), do: gettext("Cookie rejected")
  def cause(:limit), do: gettext("Limit reached")
  def cause(:invalid_json), do: gettext("The answer is not valid JSON")
  def cause(:invalid_xml), do: gettext("The answer is not valid XML")
  def cause(:xml_dtd), do: gettext("The answer holds a DTD, which Cinder refuses")
  def cause(:no_results_list), do: gettext("The answer has no results list")
  def cause({:http_status, 410}), do: gettext("Disabled in Prowlarr")
  def cause({:http_status, 404}), do: gettext("Not found in Prowlarr")
  def cause({:http_status, status}), do: gettext("HTTP %{status}", status: status)
  def cause({:indexer_error, code}), do: gettext("Indexer error %{code}", code: code)
  def cause({:query_error, code}), do: gettext("Query refused (code %{code})", code: code)
  def cause(_other), do: gettext("Failed")

  defp failures(count),
    do: ngettext("%{count} failure in a row", "%{count} failures in a row", count)

  @doc """
  The name of a feature code, as "Not supported: %{feature}" shows it: an indexer state's, and
  a definition load result's in the Prowlarr import (`CinderWeb.ProwlarrImportText`).
  """
  @spec feature(term()) :: String.t()
  def feature(:flaresolverr), do: "FlareSolverr"
  def feature(:newznab), do: "Newznab"
  def feature(:torznab), do: "Torznab"
  def feature(:cardigann), do: "Cardigann"
  def feature(feature) when is_atom(feature), do: Atom.to_string(feature)

  # A load result's code that names its kind and the one it uses, such as `{:login, "form"}`.
  def feature({kind, used}) when is_atom(kind) and (is_atom(used) or is_binary(used)),
    do: "#{feature(kind)} #{used}"

  def feature(feature), do: inspect(feature)

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
