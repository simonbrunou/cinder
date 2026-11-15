defmodule Cinder.Download.Progress do
  @moduledoc """
  The progress rules every in-flight download shares, whatever it downloads (a movie, a TV grab,
  a book grab): which reported metrics a writer records, and when progress counts as moved.

  The download watch (`Cinder.Download.Watch`) hands each kind's writer a client report; the
  writer records `changes/2` and advances its `download_progress_at` clock only when
  `advanced?/2` says so, which is what the stall reaper reads.
  """

  import Ecto.Changeset, only: [force_change: 3, get_field: 2]

  @metric_fields [:download_progress, :download_speed, :download_eta]

  @doc """
  The metrics in `report` that `record` should record: `download_progress`, `download_speed` and
  `download_eta`, minus any that equal what `record` holds. A progress lower than the recorded
  one is dropped, so a client that briefly under-reports never walks the bar backwards.
  """
  def changes(record, report) do
    report
    |> Map.take(@metric_fields)
    |> keep_high_water(record.download_progress)
    |> Map.reject(fn {field, value} -> Map.get(record, field) == value end)
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
