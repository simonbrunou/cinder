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
  (derived "couldn't find") at `@max_attempts`.
  """
  use GenServer

  require Logger

  alias Cinder.{Acquisition, Catalog, Download, Library, Notifier}
  alias Cinder.Catalog.Grab

  @default_interval 5_000
  @search_retry_after 60
  @max_attempts 10

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs one poll pass synchronously. The scheduled timer path is asynchronous."
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, config_interval())
    retry_after = Keyword.get(opts, :search_retry_after, @search_retry_after)
    {:ok, %{interval: interval, search_retry_after: retry_after}, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    do_poll(state)
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    do_poll(state)
    {:reply, :ok, state}
  end

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
    |> Enum.reject(&(&1.search_attempts >= @max_attempts))
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
        original_language: series.original_language
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
         {:ok, download_id} <- client.add(release),
         {:ok, _grab} <- Catalog.create_grab(download_id, release.protocol, episode_ids) do
      episode_ids
    else
      other ->
        Logger.warning("tv grab failed (#{release.title}): #{inspect(other)}")
        []
    end
  end

  defp bump_not_grabbed(episodes, grabbed) do
    episodes
    |> Enum.map(& &1.id)
    |> Enum.reject(&(&1 in grabbed))
    |> Catalog.increment_search_attempts()
  end

  # Fresh episodes (search_attempts == 0) attempt immediately; failed ones back off to once per
  # `retry_after` seconds. retry_after 0 (test) makes everything due. Mirrors the movie poller.
  defp search_due?(_episode, 0), do: true
  defp search_due?(%{search_attempts: 0}, _retry_after), do: true

  defp search_due?(episode, retry_after),
    do: DateTime.diff(DateTime.utc_now(), episode.updated_at) >= retry_after

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

  # Per-unit isolation: an unexpected raise OR exit (e.g. a DBConnection checkout timeout under
  # two-poller write contention — not rescue-able) skips that one unit instead of crashing the
  # whole tick. The next tick re-derives the work.
  defp isolate(label, fun) do
    fun.()
  rescue
    e -> Logger.error("tv poller skipped #{label}: #{Exception.message(e)}")
  catch
    kind, value -> Logger.error("tv poller skipped #{label}: #{inspect({kind, value})}")
  end

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)

  defp config_interval do
    :cinder
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:interval, @default_interval)
  end
end
