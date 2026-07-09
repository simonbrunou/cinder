defmodule Cinder.Download.TvPoller do
  @moduledoc """
  The TV sibling of `Cinder.Download.Poller`. Polls the episode pipeline on each tick:

  1. **advance** — checks in-flight grabs (`list_grabs_downloading`); a completed download with a
     `content_path` is marked downloaded, an anomalous/errored one is bounded-retried and parked.
  2. **import** — imports downloaded grabs (`list_grabs_downloaded`) via `Library.import_episodes`,
     mapping each file to its episode; on success the grab is finalized, on a transient FS error
     it is bounded-retried, on a deterministic empty import it is parked (its episodes re-search).
  3. **search** — sweeps `wanted_episodes`, skipping search-parked and backed-off episodes, groups
     them by `{series, season}`, and grabs the best release(s) per `Acquisition.best_releases`.

  Holds no in-flight state: every tick re-derives its work from the DB, so it recovers cleanly
  after a crash/restart — the same OTP payoff the movie poller proves. State and the download
  client are shared with the movie pipeline (`Cinder.Download.client_for/1`); episode/grab writes
  go through `Cinder.Catalog` choke-points, so the WAL + `busy_timeout` correctness holds.

  Bounded retry uses the grab's `download_attempts` counter; `mark_grab_downloaded` resets it at
  the download→import boundary, so the advance and import phases each get a fresh `@max_attempts`
  budget (a download's blips don't starve its import). The search phase backs off per
  `episode.search_attempts`/`updated_at` exactly like the movie poller, and an episode parks
  (derived `:search_parked`) at `Catalog.max_search_attempts/0` — the crossing is warned +
  announced by Catalog at the counter's write site, covering every bump path.
  """
  require Logger

  alias Cinder.{Acquisition, Catalog, Download, Library, Notifier}
  alias Cinder.Catalog.Grab

  @default_interval 5_000
  @search_retry_after 60
  @max_attempts 10

  # Download-side failures that only reach park after exhausting @max_attempts retries
  # (advance_with/2) — symmetric with the movie poller's @download_failure_errors. Past
  # exhaustion the release itself is the problem, so the grab's release is blocklisted.
  @download_failure_errors [:download_error, :torrent_not_found, :no_content_path]

  use Cinder.Download.PollerSkeleton, log_prefix: "tv poller"

  defp do_poll(state) do
    advance_grabs()
    import_grabs()
    search_wanted(state.search_retry_after)
    :ok
  end

  # --- advance: in-flight downloads ------------------------------------------------------------

  defp advance_grabs do
    for grab <- Catalog.list_grabs_downloading(),
        do: isolate("grab #{grab.id}", fn -> advance(grab) end)
  end

  defp advance(grab) do
    case Download.client_for(grab.download_protocol) do
      {:ok, client} -> advance_with(grab, client)
      # No client for this grab's protocol (e.g. removed from config mid-download): bound it so
      # it parks instead of re-raising every tick.
      :error -> retry_or_park(grab, :no_client)
    end
  end

  defp advance_with(grab, client) do
    case client.status(grab.download_id) do
      {:ok, %{state: :completed, content_path: path}} when path not in [nil, ""] ->
        Catalog.mark_grab_downloaded(grab, path)

      # Completed but no usable path / errored / vanished: anomalous, so bound it rather than
      # re-polling forever. A still-downloading or transient client error just waits (no bump).
      {:ok, %{state: :completed}} ->
        retry_or_park(grab, :no_content_path)

      {:ok, %{state: :error}} ->
        retry_or_park(grab, :download_error)

      {:error, :not_found} ->
        retry_or_park(grab, :torrent_not_found)

      _ ->
        :ok
    end
  end

  # --- import: downloaded grabs ----------------------------------------------------------------

  defp import_grabs do
    for grab <- Catalog.list_grabs_downloaded(),
        do: isolate("grab #{grab.id}", fn -> import_grab(grab) end)
  end

  defp import_grab(grab) do
    case Library.import_episodes(grab.content_path, grab.episodes) do
      {:ok, [], _unmatched} ->
        # Deterministic: nothing in content_path mapped to a grab episode. Re-importing can't
        # help, so park — the episodes re-search (bounded), rather than re-importing forever.
        Logger.warning("tv grab #{grab.id} imported nothing from #{grab.content_path}; parking")
        park(grab, :no_files_matched)

      {:ok, imported, _unmatched} ->
        # Notify only when the finalize transaction commits — otherwise a rolled-back finish_grab
        # would leave the grab undeleted (re-imported next tick) while emitting a false, repeating
        # available event. Mirrors the movie poller's `with {:ok, _} <- transition` guard.
        with {:ok, _grab} <- Catalog.finish_grab(grab, imported) do
          notify_available(grab, imported)
          # After the finalize commit: best-effort, gated remove of the source download.
          # Read id/protocol off the in-hand grab — finish_grab deleted the row but returns
          # the in-memory struct. A partial-match pack still removes (don't strand clutter).
          Download.remove_after_import(grab.download_protocol, grab.download_id)
        end

      # A missing TV root is a config error, not a transient one: leave the grab downloaded
      # (no bump, no park) so the already-downloaded content imports as soon as tv_library_path
      # is set — parking would delete the download and re-search the episode for nothing.
      {:error, :library_not_configured} ->
        Logger.warning(
          "tv grab #{grab.id}: tv_library_path not set; holding the download until it is configured"
        )

      # Every remaining error is transient (a filesystem hiccup): the one deterministic
      # "unusable content" case surfaces as {:ok, [], _} above and is parked immediately, so
      # unlike the movie poller there is no @permanent_*_errors set to classify here.
      {:error, reason} ->
        retry_or_park(grab, reason)
    end
  end

  # --- search: wanted episodes -----------------------------------------------------------------

  defp search_wanted(retry_after) do
    Catalog.wanted_episodes()
    |> Enum.reject(&(&1.search_attempts >= Catalog.max_search_attempts()))
    |> Enum.filter(&search_due?(&1, retry_after))
    |> Enum.group_by(&{&1.season.series.id, &1.season.season_number})
    |> Enum.each(fn {{series_id, season}, episodes} ->
      isolate("series #{series_id} s#{season}", fn -> search_group(episodes) end)
    end)
  end

  defp search_group(episodes) do
    series = hd(episodes).season.series
    season_number = hd(episodes).season.season_number
    numbers = Enum.map(episodes, & &1.episode_number)

    opts =
      [
        protocols: Download.available_protocols(),
        preferred_language: series.preferred_language,
        original_language: series.original_language,
        release_blocklist: Catalog.blocked_release_titles_for_series(series.id)
      ] ++ Acquisition.band_opts(:tv)

    case Acquisition.best_releases(series, season_number, numbers, opts) do
      {:ok, assignments} ->
        grabbed = Enum.flat_map(assignments, &grab_assignment(&1, episodes))
        bump_not_grabbed(episodes, grabbed)

      :no_match ->
        bump_not_grabbed(episodes, [])

      {:error, reason} ->
        Logger.info(
          "tv search failed for series #{series.id} season #{season_number}: #{inspect(reason)}"
        )

        bump_not_grabbed(episodes, [])
    end
  end

  # Add one chosen release to its client and create the grab linking exactly the episodes it
  # covers. Returns the linked episode ids (so the caller backs off only the rest).
  defp grab_assignment({release, covered_numbers}, episodes) do
    episode_ids =
      episodes |> Enum.filter(&(&1.episode_number in covered_numbers)) |> Enum.map(& &1.id)

    with {:ok, client} <- Download.client_for(release.protocol),
         {:ok, download_id} <- client.add(release) do
      case create_grab_safely(download_id, release, episode_ids) do
        {:ok, _grab} ->
          episode_ids

        {:error, reason} ->
          # The client download was already added: remove it (best-effort) so a failed
          # link — a concurrent grab or an admin cancel took the episodes — doesn't
          # leave an orphaned full-season download (mirrors the manual grab path).
          Logger.warning("tv grab failed (#{release.title}): #{inspect(reason)}")
          Download.best_effort_remove(client, download_id)
          []
      end
    else
      other ->
        Logger.warning("tv grab failed (#{release.title}): #{inspect(other)}")
        []
    end
  end

  # A raised/exited create_grab (SQLITE_BUSY past busy_timeout, a pool-checkout
  # timeout under two-poller contention) must reach the cleanup branch above, not
  # escape to isolate/2 — that would skip the download removal and orphan it.
  defp create_grab_safely(download_id, release, episode_ids) do
    Catalog.create_grab(download_id, release.protocol, episode_ids, release.title)
  rescue
    e -> {:error, e}
  catch
    kind, value -> {:error, {kind, value}}
  end

  # Crossing the search cap is announced by Catalog.increment_search_attempts itself (at the
  # write site, so the finish_grab/park_grab bump path announces too — not just this sweep).
  defp bump_not_grabbed(episodes, grabbed) do
    episodes
    |> Enum.map(& &1.id)
    |> Enum.reject(&(&1 in grabbed))
    |> Catalog.increment_search_attempts()
  end

  # --- shared helpers --------------------------------------------------------------------------

  # Bounded retry on the grab's single lifetime counter: keep it where it is and retry next tick,
  # but after @max_attempts park it (delete + bump its episodes' search_attempts) so a persistent
  # failure surfaces instead of looping forever.
  defp retry_or_park(%Grab{} = grab, reason) do
    attempts = (grab.download_attempts || 0) + 1

    if attempts >= @max_attempts do
      Logger.warning("tv grab #{grab.id} exhausted after #{attempts}: #{inspect(reason)}")
      park(grab, reason)
    else
      Logger.info(
        "tv grab #{grab.id} attempt #{attempts}/#{@max_attempts} failed (#{inspect(reason)}); will retry"
      )

      Catalog.increment_grab_attempts(grab)
    end
  end

  # Single terminal-park choke-point: drop the grab and notify, mirroring the movie poller's
  # park/3. Both TV terminal-park sites (empty import, retry exhaustion) route through here so a
  # failed grab is never silent — symmetric with {:movie_failed, _, _}.
  defp park(grab, reason) do
    # Block BEFORE park_grab deletes the grab: block_grab_release resolves the series from the
    # grab's still-linked episodes (the grab_id FK nilifies them on delete). It is non-raising,
    # so it cannot abort the park (a raise here would re-park the grab every tick). :no_files_matched
    # is the deterministic empty-import; the download-side reasons only reach park post-exhaustion.
    if reason == :no_files_matched or reason in @download_failure_errors do
      Catalog.block_grab_release(grab, reason)
    end

    Catalog.park_grab(grab)
    Notifier.notify({:grab_failed, grab, reason})
  end

  # On a successful import, announce the episodes that landed — the TV analogue of
  # {:movie_available, movie}. The grab fans out to N episodes, so the event carries the list;
  # filter the grab's preloaded episodes to the imported ids (the grab is deleted by finish_grab,
  # but its in-memory episodes — with season: :series preloaded — remain for the event payload).
  defp notify_available(grab, imported) do
    imported_ids = MapSet.new(imported, fn {id, _dest, _q} -> id end)
    episodes = Enum.filter(grab.episodes, &MapSet.member?(imported_ids, &1.id))
    Notifier.notify({:episodes_available, episodes})
  end
end
