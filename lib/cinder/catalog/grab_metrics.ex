defmodule Cinder.Catalog.GrabMetrics do
  @moduledoc """
  The download-metrics write that TV grabs (`Cinder.Catalog.Grabs.update_grab_download_metrics/2`)
  and book grabs (`Cinder.Books.Grabs.track/2`) share: the writer contract `Cinder.Download.Watch`
  documents, on a table whose row means "still downloading" while its `content_path` is unset.
  Each caller passes only what differs, its row and how to announce the written row.

  `Catalog.MovieLifecycle.track/2` is not one of them: a movie's guard is its status.
  """
  import Ecto.Query

  alias Cinder.Books.BookGrab
  alias Cinder.Catalog.Grab
  alias Cinder.Download.Progress
  alias Cinder.Repo

  @doc """
  Records the metrics in `attrs` on `grab` (`Cinder.Download.Progress.changes/2`), then calls
  `announce` with the written row.

    * The write lands only while `content_path` is still unset. A report for a grab the import
      phase already claimed is stale: `{:error, :stale_grab}`, nothing written, nothing announced.
    * A regressed `download_progress` is dropped from the write, so a client that briefly
      under-reports never walks the operator-visible bar backwards.
    * `download_progress_at` advances to now only on forward progress (`Progress.advanced?/2`).
      The completion edge is the caller's mark-downloaded write's to advance, since this write
      never runs once `content_path` is set. The end of a client pause moves it by the paused
      time (`Progress.changes/3`) when no forward progress came with it.
    * A report that changes nothing writes and announces nothing. It returns `grab` as passed
      while the row is still downloading, and `{:error, :stale_grab}` once it is not.
  """
  @spec write(grab, map(), (grab -> any())) :: {:ok, grab} | {:error, :stale_grab}
        when grab: Grab.t() | BookGrab.t()
  def write(%schema{} = grab, attrs, announce)
      when schema in [Grab, BookGrab] and is_function(announce, 1) do
    changes = Progress.changes(grab, attrs)

    if changes == %{},
      do: confirm_downloading(grab),
      else: record(grab, changes, announce)
  end

  defp confirm_downloading(%schema{} = grab) do
    if Repo.exists?(downloading(schema, grab.id)), do: {:ok, grab}, else: {:error, :stale_grab}
  end

  defp record(%schema{} = grab, changes, announce) do
    now = DateTime.utc_now(:second)

    changes =
      if Progress.advanced?(grab.download_progress, Map.get(changes, :download_progress)),
        do: Map.put(changes, :download_progress_at, now),
        else: changes

    case Repo.update_all(select(downloading(schema, grab.id), [g], g),
           set: Map.to_list(changes) ++ [updated_at: now]
         ) do
      {1, [updated]} ->
        announce.(updated)
        {:ok, updated}

      {0, _none} ->
        {:error, :stale_grab}
    end
  end

  defp downloading(schema, id),
    do: from(g in schema, where: g.id == ^id and is_nil(g.content_path))
end
