defmodule Cinder.Download.Progress do
  @moduledoc """
  The progress rules every in-flight download shares, whatever it downloads (a movie, a TV grab,
  a book grab): which reported metrics a writer records, and when progress counts as moved.

  The download watch (`Cinder.Download.Watch`) hands each kind's writer a client report; the
  writer records `changes/2` and advances its `download_progress_at` clock only when
  `advanced?/2` says so, which is what the stall reaper reads.
  """

  import Ecto.Changeset, only: [force_change: 3, get_field: 2]

  alias Cinder.Download.StallReaper

  @metric_fields [:download_progress, :download_speed, :download_eta]

  # How far past the reaper's cap a clock must be, at the first paused report, for the pause to be
  # dated from the clock. A clock inside this margin (twelve default poll intervals) may just have
  # crossed the cap while running, so the resume still reaps it. One past it suggests the reaper
  # did not reach the row before that report: Cinder was down, the client was unreachable, a poll
  # pass ran long, or the reaper was off.
  @unwatched_margin_seconds 60

  @doc """
  The fields in `report` that `record` should record: `download_progress`, `download_speed` and
  `download_eta`, minus any that equal what `record` holds. A progress lower than the recorded
  one is dropped, so a client that briefly under-reports never walks the bar backwards.

  A `client_paused` key in `report` also tracks, on the row, a hold the download client put on this
  download (`Cinder.Download.Client.status/1`): its whole queue paused, this download stopped or
  paused, or a wait behind its queue limit:

    * `true` on a row with no pause sets `download_paused_at` to `now`. When the row's clock is
      more than a minute past the reaper's cap, the reaper may not have reached the row before
      this report, so the pause is dated from the clock and the resume gives a full window.
    * `false` on a paused row clears `download_paused_at` and moves `download_progress_at` forward
      by the time since the later of the pause and the last progress. Running time before and
      after the pause still counts toward the cap. A row with no clock gets `now`.
    * Any other report, or no key, leaves the pause as it is, so a paused row whose metrics hold
      still writes nothing per tick and a client that stops answering does not end a pause.
  """
  def changes(record, report, now \\ DateTime.utc_now(:second)) do
    report
    |> Map.take(@metric_fields)
    |> keep_high_water(record.download_progress)
    |> Map.reject(fn {field, value} -> Map.get(record, field) == value end)
    |> Map.merge(pause_changes(record, Map.get(report, :client_paused), now))
  end

  defp pause_changes(%{download_paused_at: nil} = record, true, now),
    do: %{download_paused_at: pause_start(record.download_progress_at, now)}

  defp pause_changes(%{download_paused_at: %DateTime{} = paused_at} = record, false, now) do
    %{
      download_paused_at: nil,
      download_progress_at: resumed_clock(record.download_progress_at, paused_at, now)
    }
  end

  defp pause_changes(_record, _client_paused, _now), do: %{}

  defp pause_start(nil, now), do: now

  defp pause_start(clock, now) do
    unwatched_after = div(StallReaper.max_downloading_timeout(), 1000) + @unwatched_margin_seconds

    if DateTime.diff(now, clock) > unwatched_after, do: clock, else: now
  end

  defp resumed_clock(nil, _paused_at, now), do: now

  defp resumed_clock(clock, paused_at, now) do
    paused_from = if DateTime.after?(clock, paused_at), do: clock, else: paused_at

    DateTime.add(clock, max(DateTime.diff(now, paused_from), 0))
  end

  @doc "True when `current` progress is a number past `previous` (nil counts as 0)."
  def advanced?(previous, current) when is_number(current), do: current > (previous || 0)
  def advanced?(_previous, _current), do: false

  @doc """
  The `download_progress_at` step of a grab's changeset (`Cinder.Catalog.Grab`,
  `Cinder.Books.BookGrab`), where `grab` is the changeset's data. The clock moves to now on
  insert, on the completion edge (`content_path` going from unset to set, or back), and on forward
  progress (`advanced?/2`). A speed or ETA change alone leaves it, so a client that reports churn
  without progress cannot postpone a stall reap. A movie keys its clock on its status instead.
  """
  def advance_clock(%Ecto.Changeset{} = changeset, grab) do
    progress = get_field(changeset, :download_progress)
    content_path = get_field(changeset, :content_path)

    if is_nil(grab.id) or is_nil(content_path) != is_nil(grab.content_path) or
         advanced?(grab.download_progress, progress) do
      force_change(changeset, :download_progress_at, DateTime.utc_now(:second))
    else
      changeset
    end
  end

  defp keep_high_water(%{download_progress: progress} = report, previous)
       when is_number(progress) and (is_nil(previous) or progress >= previous),
       do: report

  defp keep_high_water(report, _previous), do: Map.delete(report, :download_progress)
end
