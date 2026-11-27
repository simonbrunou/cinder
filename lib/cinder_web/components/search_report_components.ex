defmodule CinderWeb.SearchReportComponents do
  @moduledoc """
  What the two manual-search panels (`CinderWeb.ManualSearchComponent` and
  `CinderWeb.BookManualSearchComponent`) say about the search itself, read from its
  `Cinder.Acquisition.IndexerSource.Report` and its error.

  - `unanswered_indexers/1`: one line naming each indexer the report lists as failed or skipped,
    with its reason. An indexer that answered or was not asked is left out.
  - `search_error/1` and `search_error_text/2`: one text per search error.
  - `show_incomplete_line?/2`: whether the panel shows "Some indexers could not be reached;
    results may be incomplete.".
  - `search_status/1`: the panel's live region, which holds the loading line, these lines and
    "No releases found.", and never a result row.

  Every time these texts show is in the household's time zone, as hours and minutes, with the
  date first when the day is not the household's today
  (`CinderWeb.LiveHelpers.household_time_parts/2`).
  """
  use Phoenix.Component
  use Gettext, backend: CinderWeb.Gettext

  import CinderWeb.CoreComponents, only: [icon: 1]
  import CinderWeb.LiveHelpers, only: [household_time_parts: 2]

  alias Cinder.Acquisition.IndexerSource.Report

  @doc """
  A result row's indexer: the release's `indexer_name` as the source sent it, untranslated, or
  nothing when the release has no name.
  """
  attr :release, :map, required: true

  def indexer_name(assigns) do
    ~H"""
    <span
      :if={Map.get(@release, :indexer_name) not in [nil, ""]}
      class="text-xs text-base-content/60"
      data-indexer
    >
      {@release.indexer_name}
    </span>
    """
  end

  @doc """
  The "Not every indexer answered: ..." line, or nothing when `report` is `nil` or lists no
  failed or skipped indexer. Each item is the indexer's name, with its reason in parentheses when
  the reason is one this module knows. Items run by name, then by key.
  """
  attr :id, :string, required: true
  attr :report, :any, default: nil, doc: "a `Report`, or `nil` for none"
  attr :now, :any, default: nil, doc: "the `DateTime` a time compares with; `nil` for now"

  def unanswered_indexers(assigns) do
    assigns = assign(assigns, :items, unanswered_items(assigns.report, assigns.now))

    ~H"""
    <p :if={@items != []} id={@id} class="mb-2 text-xs text-warning">
      {gettext("Not every indexer answered: %{list}.", list: Enum.join(@items, ", "))}
    </p>
    """
  end

  defp unanswered_items(%Report{indexers: indexers}, now) do
    now = now || DateTime.utc_now()

    for {key, %{name: name, outcome: {class, reason}}} <- indexers,
        class in [:failed, :skipped] do
      {name, key, reason}
    end
    |> Enum.sort()
    |> Enum.map(fn {name, _key, reason} -> item(name, reason_text(reason, now)) end)
  end

  defp unanswered_items(_report, _now), do: []

  defp item(name, nil), do: name
  defp item(name, reason), do: gettext("%{name} (%{reason})", name: name, reason: reason)

  # One text per reason tag of `Report`'s closed set. A tag this module does not know gives
  # `nil`, so the item shows the name alone and never the term.
  defp reason_text(:timeout, _now), do: gettext("timed out")

  defp reason_text(reason, _now) when reason in [:dns, :connection_refused, :connection_failed],
    do: gettext("couldn't connect")

  defp reason_text({:http_status, status}, _now) when is_integer(status),
    do: gettext("HTTP %{status}", status: status)

  defp reason_text(:bad_response, _now), do: gettext("unreadable answer")
  defp reason_text(:too_large, _now), do: gettext("answer too large")

  defp reason_text({:indexer_error, code}, _now) when is_integer(code),
    do: gettext("error code %{code}", code: code)

  # Each sentence with a time has a second msgid for another day, so a translator words the
  # date itself ("jusqu'au 5 juin à 14:35", not "jusqu'à 5 juin à 14:35").
  defp reason_text({:limit, %DateTime{} = until}, now) do
    case household_time_parts(until, now) do
      {nil, time} ->
        gettext("limit reached, searching again at %{time}", time: time)

      {date, time} ->
        gettext("limit reached, searching again on %{date} at %{time}", date: date, time: time)
    end
  end

  defp reason_text(:rejected_credentials, _now), do: gettext("credentials rejected")
  defp reason_text(:challenge, _now), do: gettext("blocked by a challenge page")
  defp reason_text(:crashed, _now), do: gettext("search crashed")

  defp reason_text({:backoff, %DateTime{} = until}, now) do
    case household_time_parts(until, now) do
      {nil, time} -> gettext("waiting until %{time}", time: time)
      {date, time} -> gettext("waiting until %{date}, %{time}", date: date, time: time)
    end
  end

  defp reason_text(:deadline, _now), do: gettext("cut off by the search deadline")
  defp reason_text(_reason, _now), do: nil

  @doc """
  The text a panel shows for a search that ended in `{:error, reason}`, or for a search task that
  exited (`{:exit, reason}`, as the panels store it). `now` is the `DateTime` a time compares
  with.

  - `{:no_indexer_answered, report}`: "No indexer answered. Try again." The panel shows the
    report's `unanswered_indexers/1` line beside it.
  - `:no_indexers`: "No indexer is enabled. Add one in Settings."
  - `{:indexers_backing_off, retry_at}`: "Every indexer is waiting until %{time}."
  - `{:anime_policy, reason}` (the video panel's anime preferences error), `{:exit, reason}` and
    `nil`: "The search failed. Try again."
  - Every other reason, such as the Prowlarr source's errors: "Couldn't reach Prowlarr. Try
    again."
  """
  @spec search_error_text(term(), DateTime.t()) :: String.t()
  def search_error_text(reason, now \\ DateTime.utc_now())

  def search_error_text({:no_indexer_answered, %Report{}}, _now),
    do: gettext("No indexer answered. Try again.")

  def search_error_text(:no_indexers, _now),
    do: gettext("No indexer is enabled. Add one in Settings.")

  def search_error_text({:indexers_backing_off, %DateTime{} = retry_at}, now) do
    case household_time_parts(retry_at, now) do
      {nil, time} ->
        gettext("Every indexer is waiting until %{time}.", time: time)

      {date, time} ->
        gettext("Every indexer is waiting until %{date}, %{time}.", date: date, time: time)
    end
  end

  def search_error_text(reason, _now)
      when is_nil(reason) or (is_tuple(reason) and elem(reason, 0) in [:anime_policy, :exit]),
      do: gettext("The search failed. Try again.")

  def search_error_text(_reason, _now), do: gettext("Couldn't reach Prowlarr. Try again.")

  @doc "The report a `{:no_indexer_answered, report}` error carries, or `nil` for any other."
  @spec error_report(term()) :: Report.t() | nil
  def error_report({:no_indexer_answered, %Report{} = report}), do: report
  def error_report(_reason), do: nil

  @doc """
  Whether a panel shows "Some indexers could not be reached; results may be incomplete.": when
  `report` (a `Report`, or `nil` for none) counts a failed seam call, or when `complete?` is
  false. The video panel passes `true` for `complete?`, so there only a failed seam call shows
  it; the book panel passes its results' `complete?`.
  """
  @spec show_incomplete_line?(Report.t() | nil, boolean()) :: boolean()
  def show_incomplete_line?(%Report{failed_calls: calls}, _complete?) when calls > 0, do: true
  def show_incomplete_line?(_report, complete?), do: not complete?

  @doc """
  A failed search's text (`search_error_text/2`, with the id `<id>-error`, after a
  `hero-exclamation-circle` icon that `CinderWeb.CoreComponents.icon/1` marks `aria-hidden`) and,
  for a `{:no_indexer_answered, report}` error, that report's `unanswered_indexers/1` line (with
  the id `<id>-unanswered`).
  """
  attr :id, :string, required: true, doc: "the panel's id"
  attr :error, :any, required: true, doc: "the search's error reason, as the panel stores it"

  def search_error(assigns) do
    ~H"""
    <div>
      <p id={"#{@id}-error"} class="flex items-center gap-1 text-sm text-error">
        <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
        {search_error_text(@error)}
      </p>
      <.unanswered_indexers id={"#{@id}-unanswered"} report={error_report(@error)} />
    </div>
    """
  end

  @doc """
  A panel's live region: a `div` with the id `<id>-status`, `role="status"` and
  `aria-live="polite"`, around `inner_block`. Each panel renders it in every state, the loading
  one included, so the region is already on the page when the search ends and a screen reader
  announces the lines it then holds. A panel puts in it the lines about the search (the loading
  line, `search_error/1`, the incomplete and unanswered lines, "No releases found."), never a
  result row or a Grab button, so a loaded list is not read out row by row. A search that ends
  with rows and none of those lines leaves the region empty, and nothing is announced.
  """
  attr :id, :string, required: true, doc: "the panel's id"
  slot :inner_block, required: true

  def search_status(assigns) do
    ~H"""
    <div id={"#{@id}-status"} role="status" aria-live="polite">
      {render_slot(@inner_block)}
    </div>
    """
  end
end
