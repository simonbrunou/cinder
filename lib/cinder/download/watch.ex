defmodule Cinder.Download.Watch do
  @moduledoc """
  The download watch: one verdict per in-flight download per tick.

  The movie, upgrade, TV and book pollers each hand `check/2` their in-flight download (a
  `Cinder.Catalog.Movie`, `Cinder.Catalog.Grab` or `Cinder.Books.BookGrab`) and their kind's
  metrics writer, and get back one `t:verdict/0`. What each verdict does to the kind (re-queue,
  park, revert, hold) stays in the poller, because that does differ by kind. Everything before it
  is the same for every kind and lives here:

  1. Look up the protocol's client (`Cinder.Download.client_for/1`).
  2. Ask it for the download's status.
  3. Vet the file list (`Cinder.Download.ContentPolicy.vet/2`) on `:downloading` AND on
     `:completed` with a path. Blocked content is small enough to finish between two ticks, so the
     first status a poller ever sees for it is often `:completed`; vetting only in flight misses
     exactly that download.
  4. While `:downloading`, record progress, speed and ETA through the writer, THEN ask the stall
     reaper, on the progress clock that write returned. After an outage longer than the reaper's
     absolute cap, the clock the row carried at tick start is stale by definition, so reading it
     first reaps a healthy download.
  5. Ask the reaper only while it is switched on (`StallReaper.enabled?/0`): `reap?/4` is a pure
     predicate that knows nothing about the operator's switch.

  The writer is the only write this module makes, and it never writes a status: every status
  change stays behind the Catalog and Books choke-points the pollers call. The writer is called as
  `track.(download, attrs)` with `attrs` a subset of `download_progress`, `download_speed` and
  `download_eta`, and must answer `{:ok, record}` with the record's `download_progress_at` after
  the write, or `{:error, reason}`: `Catalog.update_movie_download_metrics/2`,
  `Catalog.update_grab_download_metrics/2` and `Books.Grabs.track/2` all do.

  Nothing here raises on a client or writer answer. A raise inside a poller's `isolate/2` would
  re-fire every tick with nothing parked, so every answer becomes a verdict instead.

  ## Reasons

  `{:failed, reason}` carries the same reason atoms for every kind, because they are persisted:
  blocklist rows, book hold reasons, notifications and both video pollers'
  `@download_failure_errors` read them.

  - `:no_content_path`: the client reports `:completed` with no usable path.
  - `:download_error`, or `{:download_error, detail}` when the client gave a human-facing reason
    (SABnzbd's paused state or `fail_message`).
  - `:torrent_not_found`: the client does not know the job, for usenet too. Every adapter reports
    the moment a job moves between queue and history the same way, so the pollers bound this
    before acting rather than acting on the first sighting.
  """

  require Logger

  alias Cinder.Download
  alias Cinder.Download.{ContentPolicy, StallReaper}
  alias Cinder.HTTPPolicy

  @typedoc "An in-flight download row: a movie, a TV grab or a book grab."
  @type download :: %{
          required(:download_id) => String.t(),
          required(:download_protocol) => atom() | nil,
          required(:updated_at) => DateTime.t(),
          optional(atom()) => term()
        }

  @typedoc "The kind's metrics writer; see the moduledoc."
  @type track :: (download(), map() ->
                    {:ok, %{required(:download_progress_at) => DateTime.t() | nil}}
                    | {:error, term()})

  @type failure ::
          :no_content_path | :download_error | {:download_error, String.t()} | :torrent_not_found

  @typedoc """
  - `{:completed, content_path}`: finished, file list clean, `content_path` non-empty.
  - `:downloading`: still in flight, file list clean, metrics recorded (or the write was
    refused, which is logged), not stalled.
  - `{:failed, reason}`: the client says this download went wrong; see "Reasons".
  - `{:blocked_content, detail}`: the file list marks the release as a fake. Deterministic, so a
    poller acts on the first sighting. `detail` names the file, sanitized.
  - `:stalled`: metrics recorded, the reaper is on, and the download is past its window.
  - `:no_client`: no client is configured for the download's protocol. Nothing was called.
  - `{:unreachable, reason}`: the status call failed, or answered outside the client contract.
    Live speed and ETA were cleared through the writer; progress is kept.
  """
  @type verdict ::
          {:completed, String.t()}
          | :downloading
          | {:failed, failure()}
          | {:blocked_content, String.t()}
          | :stalled
          | :no_client
          | {:unreachable, term()}

  @doc "Watches `download` for one tick and returns its verdict. See the moduledoc."
  @spec check(download(), track()) :: verdict()
  def check(download, track) do
    case Download.client_for(download.download_protocol) do
      {:ok, client} -> check_with(client, download, track)
      :error -> :no_client
    end
  end

  defp check_with(client, download, track) do
    case client.status(download.download_id) do
      {:ok, %{state: :completed, content_path: path}} when is_binary(path) and path != "" ->
        vetted(client, download, fn -> {:completed, path} end)

      {:ok, %{state: :completed}} ->
        {:failed, :no_content_path}

      {:ok, %{state: :error} = status} ->
        {:failed, download_error(status)}

      {:error, :not_found} ->
        {:failed, :torrent_not_found}

      {:ok, %{state: :downloading} = status} ->
        vetted(client, download, fn -> track_and_reap(download, status, track) end)

      {:ok, status} ->
        unreachable(download, track, {:unexpected_status, status})

      {:error, reason} ->
        unreachable(download, track, reason)
    end
  end

  defp download_error(%{reason: detail}) when is_binary(detail) and detail != "",
    do: {:download_error, detail}

  defp download_error(_status), do: :download_error

  defp vetted(client, download, continue) do
    case ContentPolicy.vet(client, download.download_id) do
      {:blocked, detail} -> {:blocked_content, detail}
      :ok -> continue.()
    end
  end

  defp track_and_reap(download, status, track) do
    attrs = %{
      download_progress: Map.get(status, :progress),
      download_speed: Map.get(status, :speed),
      download_eta: Map.get(status, :eta)
    }

    case track.(download, attrs) do
      {:ok, tracked} ->
        if stalled?(download, tracked.download_progress_at, status),
          do: :stalled,
          else: :downloading

      # Never silent: a refused write freezes the progress clock, and a frozen clock is what the
      # reaper's absolute cap reads. Usually the row left the download phase mid-tick.
      {:error, reason} ->
        Logger.warning(
          "download #{HTTPPolicy.sanitize_log(download.download_id)} progress not recorded: " <>
            inspect(reason)
        )

        :downloading
    end
  end

  # The seed window keeps the tick-start `updated_at` (metric writes are change-gated, so it
  # freezes while nothing moves); the absolute cap reads the clock the write returned.
  defp stalled?(download, download_progress_at, status) do
    StallReaper.enabled?() and
      StallReaper.reap?(download.updated_at, download_progress_at, status, DateTime.utc_now())
  end

  defp unreachable(download, track, reason) do
    track.(download, %{download_speed: nil, download_eta: nil})
    {:unreachable, reason}
  end
end
