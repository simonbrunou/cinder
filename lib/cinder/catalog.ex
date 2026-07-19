defmodule Cinder.Catalog do
  @moduledoc """
  Discovery: search TMDB for movies and persist requested ones.

  TMDB is reached only through the `Cinder.Catalog.TMDB` behaviour, resolved from
  config (`config :cinder, :tmdb`) so tests use a Mox mock and never hit the network.
  """
  import Ecto.Query
  require Logger

  alias Cinder.Acquisition.Release
  alias Cinder.Audit

  alias Cinder.Catalog.{
    BlockedRelease,
    Episode,
    EpisodeCoordinate,
    Grab,
    Identity,
    MediaProfile,
    Movie,
    ReleaseVerification,
    Season,
    Series
  }

  alias Cinder.Download
  alias Cinder.Download.Intent
  alias Cinder.Library
  alias Cinder.Library.ImportStage
  alias Cinder.Notifier
  alias Cinder.Repo
  alias Cinder.Util

  @topic "movies"
  @download_metric_fields [:download_progress, :download_speed, :download_eta]
  @max_search_attempts 10

  @doc """
  Searches TMDB for `query`. A blank/whitespace query short-circuits to `{:ok, []}`
  with no API call.
  """
  def search_movies(query) do
    if String.trim(query) == "" do
      {:ok, []}
    else
      tmdb().search(query)
    end
  end

  @doc "TV-search variant of `search_movies/1`: blank query short-circuits to `{:ok, []}`."
  def search_tv(query) do
    if String.trim(query) == "" do
      {:ok, []}
    else
      tmdb().search_tv(query)
    end
  end

  @doc """
  Combined Discover search: movies + TV for one query. Returns `{:ok, results}`
  where each result is a normalized search map plus a `:type` key (`:movie | :tv`),
  interleaved so both kinds surface near the top of the grid. A blank/whitespace
  query short-circuits to `{:ok, []}` with no API call. If *both* endpoints error,
  returns `{:error, :search_failed}`; if only one errors it is logged and its side
  is omitted — partial results beat none for discovery.

  ponytail: runs the two searches sequentially (matches the existing synchronous
  search style; household scale + 300ms debounce). Upgrade path if search latency
  bites: wrap each in Task.async/await_many to run them concurrently.
  """
  def search_discover(query) do
    if String.trim(query) == "" do
      {:ok, []}
    else
      merge_discover(search_movies(query), search_tv(query))
    end
  end

  defp merge_discover({:error, _} = movies, {:error, _} = tv) do
    Logger.warning("Discover search failed entirely: movies=#{inspect(movies)} tv=#{inspect(tv)}")
    {:error, :search_failed}
  end

  defp merge_discover(movies_res, tv_res) do
    {:ok, interleave(tag(movies_res, :movie), tag(tv_res, :tv))}
  end

  defp tag({:ok, list}, type), do: Enum.map(list, &Map.put(&1, :type, type))

  defp tag({:error, reason}, type) do
    Logger.warning("Discover #{type} search failed: #{inspect(reason)}")
    []
  end

  # Round-robin so a 2-col mobile grid shows both kinds near the top, then any tail.
  defp interleave(a, b) do
    0..max(length(a), length(b))
    |> Enum.flat_map(fn i -> [Enum.at(a, i), Enum.at(b, i)] end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Fetches series details (including seasons list) from TMDB by tmdb_id."
  def tmdb_series(tmdb_id), do: tmdb().get_series(tmdb_id)

  # Resolve the impl at runtime. compile_env! would inline the mock module, which —
  # being defined at runtime by Mox in test_helper.exs — doesn't exist at compile time
  # and warns under --warnings-as-errors. fetch_env! still fails fast if unconfigured.
  defp tmdb, do: Application.fetch_env!(:cinder, :tmdb)

  @doc """
  Persists a movie as `:requested`. Returns `{:ok, movie}` or
  `{:error, changeset}` (e.g. a duplicate `tmdb_id`).
  """
  def add_movie(attrs) do
    %Movie{}
    |> Movie.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Sets the operator-owned handling profile for a movie or series and broadcasts the update.
  Rescues a deleted-row race to `{:error, :stale_entry}` (mirrors write_movie_language/2) —
  the approval path calls this post-commit, where a raise would escape an already-committed
  approval.
  """
  def set_media_profile(%Movie{} = movie, profile) do
    with {:ok, updated} <-
           movie |> Movie.profile_changeset(%{media_profile: profile}) |> Repo.update() do
      broadcast({:movie_updated, updated})
      {:ok, updated}
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  def set_media_profile(%Series{} = series, profile) do
    with {:ok, updated} <-
           series |> Series.profile_changeset(%{media_profile: profile}) |> Repo.update() do
      broadcast_series(updated.id)
      {:ok, updated}
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  @doc """
  Marks a title held at search time because the Anime release preferences can't be
  satisfied for it (`AnimePreferences.resolve/2` failed), or clears the hold (`nil`).
  A non-status flag written directly (monitor-toggle precedent, not pipeline state);
  every sweep re-writes it at the resolve site, so the marker can't stick stale.
  A no-op when unchanged — the sweep runs every tick, don't broadcast equal values.
  """
  def set_anime_hold(title, reason) do
    reason = reason && to_string(reason)

    if title.anime_hold_reason == reason,
      do: {:ok, title},
      else: write_anime_hold(title, reason)
  end

  defp write_anime_hold(%Movie{} = movie, reason) do
    with {:ok, updated} <-
           movie |> Movie.anime_hold_changeset(%{anime_hold_reason: reason}) |> Repo.update() do
      broadcast({:movie_updated, updated})
      {:ok, updated}
    end
  end

  defp write_anime_hold(%Series{} = series, reason) do
    with {:ok, updated} <-
           series |> Series.anime_hold_changeset(%{anime_hold_reason: reason}) |> Repo.update() do
      broadcast_series(updated.id)
      {:ok, updated}
    end
  end

  @doc "Series currently held at search time on unsatisfiable Anime preferences (see `set_anime_hold/2`); surfaced on `/activity`."
  def list_anime_held_series do
    Repo.all(from s in Series, where: not is_nil(s.anime_hold_reason), order_by: s.title)
  end

  @doc "Returns selected/effective profile policy and bounded suggestion evidence."
  def media_profile_summary(%Series{} = series) do
    extra_evidence =
      if Repo.exists?(
           from c in EpisodeCoordinate,
             where: c.series_id == ^series.id and c.source == "tmdb" and c.scheme == "absolute"
         ),
         do: [:absolute_episode_group],
         else: []

    MediaProfile.summary(series, extra_evidence)
  end

  def media_profile_summary(%Movie{} = movie), do: MediaProfile.summary(movie)

  @doc "Returns the one series owning every supplied episode ID."
  def get_single_series_for_episode_ids(episode_ids) when is_list(episode_ids) do
    requested_ids = Enum.sort(episode_ids)

    rows =
      Repo.all(
        from e in Episode,
          join: season in Season,
          on: season.id == e.season_id,
          where: e.id in ^episode_ids,
          select: {e.id, season.series_id}
      )

    case {Enum.sort(Enum.map(rows, &elem(&1, 0))), Enum.uniq(Enum.map(rows, &elem(&1, 1)))} do
      {^requested_ids, [series_id]} -> {:ok, Repo.get!(Series, series_id)}
      _invalid -> {:error, :episode_series_mismatch}
    end
  end

  def get_single_series_for_episode_ids(_episode_ids), do: {:error, :episode_series_mismatch}

  @doc "Lists sourced aliases for a movie or series."
  defdelegate list_title_aliases(owner), to: Identity, as: :list_aliases

  @doc "Adds an operator-owned alias."
  defdelegate save_manual_alias(owner, attrs), to: Identity

  @doc "Updates an operator-owned alias belonging to the supplied owner."
  defdelegate update_manual_alias(owner, alias_id, attrs), to: Identity

  @doc "Deletes an operator-owned alias belonging to the supplied owner."
  defdelegate delete_manual_alias(owner, alias_id), to: Identity

  @doc "Lists a series' coordinates with ordered episode memberships preloaded."
  defdelegate list_episode_coordinates(series), to: Identity, as: :list_coordinates

  @doc "Lists a series' TMDB episode groups, for the alternate-numbering picker."
  def list_episode_groups(%Series{tmdb_id: tmdb_id}), do: tmdb().get_episode_groups(tmdb_id)

  @doc "Fetches one TMDB episode group's detail, for the alternate-numbering picker."
  def get_episode_group(group_id), do: tmdb().get_episode_group(group_id)

  @doc """
  Pure preview of the derived season/episode split for an already-fetched episode-group
  detail (no persistence, no further TMDB call) — shares its per-entry derivation with
  `scene_coordinate_attrs/3` (what Save actually persists) via `derive_scene_entries/2`, so
  the picker's preview can never drift from what Save writes. `series` must carry its
  preloaded season/episode tree (`Catalog.get_series_with_tree/1`); entries are matched to
  Cinder episodes by `tmdb_episode_id`. Returns one entry per derived season, sorted by
  season number, showing both sides of the mapping — the alternate S0xEyy range Save will
  write (`alt_range`) and the canonical episode range it resolves to (`canonical_range`).
  `count` reflects only entries matched to a Cinder episode row; unmatched entries (e.g. a
  Specials subgroup outside the imported tree, or an episode a Story Arc-shaped group claims from
  more than one subgroup — see `derive_scene_entries/2`) are excluded from it and surfaced
  separately via `unmatched_count`. `group_name` and `season_source` (`:name` | `:order`) expose
  the raw subgroup name and whether its season number was parsed from that name or fell back to
  subgroup order — a convention, not an API guarantee — so an order-derived season can be shown
  next to its raw name and a wrong derivation is visible before it's ever saved.
  """
  def preview_scene_mapping(%{entries: entries}, %Series{seasons: seasons}) do
    episode_lookup = episode_lookup_from_tree(seasons)

    entries
    |> derive_scene_entries(episode_lookup)
    |> Enum.group_by(& &1.season_number)
    |> Enum.map(fn {season_number, group_entries} ->
      {matched, unmatched} = Enum.split_with(group_entries, & &1.matched)
      representative = hd(group_entries)

      %{
        season_number: season_number,
        count: length(matched),
        unmatched_count: length(unmatched),
        alt_range: minmax(Enum.map(matched, & &1.episode_number)),
        canonical_range: minmax(Enum.map(matched, & &1.matched.episode_number)),
        group_name: representative.group_name,
        season_source: representative.season_source
      }
    end)
    |> Enum.sort_by(& &1.season_number)
  end

  defp episode_lookup_from_tree(seasons) do
    for season <- seasons,
        episode <- season.episodes,
        not is_nil(episode.tmdb_episode_id),
        into: %{} do
      {episode.tmdb_episode_id,
       %{
         id: episode.id,
         season_number: season.season_number,
         episode_number: episode.episode_number
       }}
    end
  end

  defp minmax([]), do: nil
  defp minmax(numbers), do: {Enum.min(numbers), Enum.max(numbers)}

  @doc """
  Sets (or clears, via `nil`/`""`) the operator-chosen TMDB episode group used for
  alternate-season numbering, syncing scene coordinates immediately. Switching away from a
  previously-chosen group clears its non-manual scene rows first, so a stale namespace can't
  linger once nothing points at it any more. The current group (`previous`) is re-read fresh from
  the DB inside the transaction rather than trusted from the caller's (possibly stale) `series`
  struct, so two racing saves can't leave an orphaned namespace behind.

  A non-nil `group_id` whose TMDB detail can't be fetched returns `{:error, :group_fetch_failed}`
  **before any transaction opens** — nothing is persisted. Unlike the refresh path's drift rule
  (a failed refresh fetch keeps whatever is already synced), there is nothing yet synced for a
  newly-chosen group, so committing the column on a failed fetch would silently strand it at zero
  coordinates while reporting success.

  `opts[:detail]` lets a caller reuse a TMDB episode-group detail it already fetched (e.g. the
  series-detail picker's own preview fetch), skipping a redundant round trip — but only when it
  was fetched for this same `group_id` (`detail.id == group_id`); otherwise it's ignored and the
  detail is fetched fresh, same as the arity-2 call.
  """
  def set_scene_numbering_group(%Series{} = series, group_id, opts \\ []) do
    group_id = Util.blank_to_nil(group_id)

    with {:ok, detail} <- resolve_scene_group_detail(group_id, opts) do
      series.id
      |> save_scene_numbering_group(group_id, detail)
      |> finish_scene_numbering_group()
    end
  end

  defp resolve_scene_group_detail(nil, _opts), do: {:ok, nil}

  defp resolve_scene_group_detail(group_id, opts) do
    case Keyword.get(opts, :detail) do
      %{id: ^group_id} = detail ->
        {:ok, detail}

      _stale_or_absent ->
        case fetch_scene_group_detail(group_id) do
          nil -> {:error, :group_fetch_failed}
          detail -> {:ok, detail}
        end
    end
  end

  defp save_scene_numbering_group(series_id, group_id, detail) do
    Repo.transaction(fn ->
      save_current_scene_numbering_group(series_id, group_id, detail)
    end)
  end

  defp save_current_scene_numbering_group(series_id, group_id, detail) do
    case Repo.get(Series, series_id) do
      %Series{} = current ->
        previous = current.scene_numbering_group_id

        with {:ok, updated} <-
               current
               |> Series.scene_numbering_changeset(%{scene_numbering_group_id: group_id})
               |> Repo.update(),
             :ok <- clear_previous_scene_namespace(updated, previous, group_id),
             :ok <- sync_scene_coordinates(updated, detail) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      nil ->
        Repo.rollback(:stale_series)
    end
  end

  defp finish_scene_numbering_group({:ok, updated}) do
    broadcast_series(updated.id)
    {:ok, updated}
  end

  defp finish_scene_numbering_group({:error, reason}), do: {:error, reason}

  defp clear_previous_scene_namespace(_series, previous, group_id)
       when previous in [nil] or previous == group_id,
       do: :ok

  defp clear_previous_scene_namespace(series, previous, _group_id) do
    case Identity.replace_provider_coordinates(series, "tmdb", previous, "scene", []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Builds the plain Catalog-owned identity context used for anime movie acquisition."
  def anime_movie_acquisition_context(%Movie{} = movie) do
    %{
      kind: :movie,
      title: movie.title,
      year: movie.year,
      aliases: acquisition_aliases(movie),
      profile: media_profile_summary(movie)
    }
  end

  @doc "Builds the plain Catalog-owned identity context used for anime series acquisition."
  def anime_series_acquisition_context(%Series{} = series) do
    episodes = acquisition_episodes(series)
    mappings = Enum.map(episodes, &canonical_mapping/1) ++ persisted_mappings(series)

    %{
      kind: :series,
      title: series.title,
      year: series.year,
      tvdb_id: series.tvdb_id,
      aliases: acquisition_aliases(series),
      episodes: episodes,
      mappings: Enum.sort_by(mappings, &mapping_sort_key/1)
    }
  end

  defp acquisition_aliases(owner) do
    owner
    |> Identity.list_aliases()
    |> Enum.map(&Map.take(&1, [:title, :kind, :precedence, :normalized_title]))
  end

  defp acquisition_episodes(series) do
    series
    |> Repo.preload(seasons: :episodes)
    |> Map.fetch!(:seasons)
    |> Enum.flat_map(fn season ->
      Enum.map(season.episodes, fn episode ->
        %{
          id: episode.id,
          season_number: season.season_number,
          episode_number: episode.episode_number,
          classification: episode.classification
        }
      end)
    end)
    |> Enum.sort_by(&{&1.season_number, &1.episode_number, &1.id})
  end

  defp canonical_mapping(episode) do
    %{
      identity: %{
        source: "cinder",
        scheme: "standard",
        namespace: "canonical",
        canonical_value: Episode.code(episode.season_number, episode.episode_number)
      },
      precedence: :manual,
      episode_ids: [episode.id],
      evidence: %{"kind" => "canonical_standard"}
    }
  end

  defp persisted_mappings(series) do
    series
    |> Identity.list_coordinates()
    |> Enum.map(fn coordinate ->
      %{
        identity: %{
          source: coordinate.source,
          scheme: coordinate.scheme,
          namespace: coordinate.namespace,
          canonical_value: coordinate.canonical_value
        },
        precedence: coordinate.precedence,
        episode_ids: Enum.map(coordinate.memberships, & &1.episode_id),
        evidence: %{"kind" => "persisted_coordinate", "coordinate_id" => coordinate.id}
      }
    end)
  end

  defp mapping_sort_key(mapping) do
    identity = mapping.identity
    {identity.source, identity.scheme, identity.namespace, identity.canonical_value}
  end

  @doc """
  Admin metadata edit for a movie (title/year/poster/ids). Reuses `Movie.changeset/2`, which
  does NOT cast `:status` — status changes go through `transition/2` (the choke-point). On success
  broadcasts `{:movie_updated, movie}` (same helper `transition/2` uses) so other subscribed
  sessions refresh. Returns `{:ok, movie}` or `{:error, changeset}`.
  """
  def update_movie(%Movie{} = movie, attrs) do
    with {:ok, updated} <- movie |> Movie.changeset(attrs) |> Repo.update() do
      broadcast({:movie_updated, updated})
      {:ok, updated}
    end
  end

  @doc "Lists movies, newest first."
  def list_movies do
    Repo.all(from m in Movie, order_by: [desc: m.id])
  end

  @doc "Maps every movie's `tmdb_id` to its pipeline `status`."
  def movie_status_map, do: Map.new(list_movies(), &{&1.tmdb_id, &1.status})

  @doc "Counts movies grouped by pipeline `status` (`%{status => count}`)."
  def movie_status_counts do
    Repo.all(from m in Movie, group_by: m.status, select: {m.status, count(m.id)}) |> Map.new()
  end

  @doc "The `limit` most-recently-updated movies, newest first (dashboard recent-activity slice)."
  def recent_movies(limit) do
    Repo.all(from m in Movie, order_by: [desc: m.updated_at], limit: ^limit)
  end

  @doc "Subscribes the caller to movie state-change broadcasts (`{:movie_updated, movie}`)."
  def subscribe, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @topic)

  @doc "Fetches full movie details from TMDB (the details endpoint carries `imdb_id`)."
  def get_movie(tmdb_id), do: tmdb().get_movie(tmdb_id)

  @doc "Fetches a movie by primary key, or `nil`."
  def get_movie_by_id(id), do: Repo.get(Movie, id)

  @doc """
  Refreshes a movie's descriptive TMDB metadata (overview/runtime/genres/rating/release date).
  Returns the refreshed `%Movie{}`; on a TMDB error it logs and returns the row unchanged so the
  detail page still renders. Descriptive, not pipeline state — writes via
  `Movie.metadata_changeset/2`, never `transition/2`.
  """
  def enrich_movie(%Movie{} = movie),
    do:
      backfill_metadata(
        movie,
        &tmdb().get_movie(&1.tmdb_id),
        &Movie.metadata_changeset/2,
        "movie"
      )

  @doc """
  Refreshes a series' descriptive TMDB metadata (overview/genres/rating/first air date) with a
  lightweight `get_series` fetch, not the full `refresh_series/1` season walk. Returns the
  refreshed `%Series{}` (or the row unchanged, logged, on a TMDB error). No broadcast — the caller
  reloads its own tree.
  """
  def enrich_series(%Series{} = series),
    do:
      backfill_metadata(
        series,
        &tmdb().get_series(&1.tmdb_id),
        &Series.metadata_changeset/2,
        "series"
      )

  # Shared descriptive-metadata refresh for a movie/series row. `fetch` and `changeset` are
  # the type's TMDB call + metadata changeset; `label` is for the log line. `updated_at` is
  # never written: this read-triggered refresh must not reorder the dashboard's Recent slice or
  # overwrite a concurrent pipeline transition's timestamp. On a TMDB error, log and return the
  # row unchanged so the page still renders.
  defp backfill_metadata(record, fetch, changeset, label) do
    case fetch.(record) do
      {:ok, info} ->
        changes = changeset.(record, info).changes

        if changes != %{} do
          schema = record.__struct__

          Repo.update_all(
            from(r in schema, where: r.id == ^record.id),
            set: Map.to_list(changes)
          )
        end

        Repo.get(record.__struct__, record.id) || record

      error ->
        Logger.warning("metadata backfill failed for #{label} #{record.id}: #{inspect(error)}")
        record
    end
  end

  @doc "Lists movies in a given pipeline `status`."
  def list_by_status(status) do
    Repo.all(from m in Movie, where: m.status == ^status)
  end

  @doc "Available movies that have an imported file (subtitle-fetch candidates)."
  def list_available_movies_with_file do
    Repo.all(from m in Movie, where: m.status == :available and not is_nil(m.file_path))
  end

  @doc "Episodes with an imported file, season+series preloaded (subtitle-fetch candidates)."
  def list_episodes_with_file do
    Repo.all(from e in Episode, where: not is_nil(e.file_path), preload: [season: :series])
  end

  @doc """
  Applies a pipeline state transition and, on success, broadcasts
  `{:movie_updated, movie}` on the `"movies"` topic. This is the single
  choke-point for state changes — every transition broadcasts exactly once.
  `attrs` must set `:status`; it may also set `:download_id`, `:download_protocol`,
  `:imdb_id`, `:file_path`, `:content_path`, `:import_attempts`, and `:search_attempts`.
  """
  def transition(movie, attrs, opts \\ [])

  def transition(%Movie{} = movie, attrs, []) do
    with {:ok, updated} <- movie |> Movie.transition_changeset(attrs) |> Repo.update() do
      broadcast({:movie_updated, updated})
      {:ok, updated}
    end
  end

  # Guarded variant (`expect: status`): the write lands only if the row's status in the
  # DB still matches — one atomic conditional UPDATE. The pollers pass the status they
  # read at tick start, so a write-back after seconds of indexer/client I/O can never
  # resurrect a movie the user cancelled (or otherwise re-decided) in that window.
  # Returns {:error, :stale_status} on a miss; callers treat it as "skip, re-derive
  # next tick". `select: m` makes SQLite RETURNING hand back the post-update row, so
  # the broadcast payload is the fresh DB state, not the poller's tick-start snapshot
  # patched in memory (views upsert the payload directly into their assigns).
  def transition(%Movie{} = movie, attrs, expect: expected) do
    movie
    |> run_guarded_movie_transition(attrs, expected)
    |> publish_guarded_movie_transition()
  end

  def transition(%Movie{} = movie, attrs, opts) when is_list(opts) do
    expected = Keyword.fetch!(opts, :expect)
    stage_ids = Keyword.get(opts, :import_stage_ids, [])

    movie
    |> run_guarded_movie_transition(attrs, expected, fn _updated ->
      ImportStage.mark_committed!(stage_ids)
    end)
    |> publish_guarded_movie_transition()
  end

  @doc false
  def account_movie_intent_retry(
        %Intent{kind: :movie, status: :reserved} = intent,
        retry_attrs,
        reason
      )
      when is_map(retry_attrs) do
    result =
      Repo.transaction(fn ->
        case claim_intent_retry_generation(intent, retry_attrs) do
          {:ok, claimed} -> account_claimed_movie_retry(claimed)
          :stale_generation -> :stale_generation
        end
      end)

    publish_movie_intent_retry(result, reason)
  end

  defp claim_intent_retry_generation(intent, retry_attrs) do
    observed_attempt = intent.attempt_count || 0

    case Repo.update_all(
           from(i in Intent,
             where:
               i.id == ^intent.id and i.status == :reserved and
                 i.attempt_count == ^observed_attempt,
             select: i
           ),
           set: Map.to_list(retry_attrs) ++ [updated_at: now()]
         ) do
      {1, [claimed]} -> {:ok, claimed}
      {0, _} -> :stale_generation
    end
  end

  defp account_claimed_movie_retry(%Intent{target_id: movie_id}) do
    case Repo.get(Movie, movie_id) do
      %Movie{status: status} = movie when status in [:requested, :searching] ->
        account_active_movie_retry(movie)

      _other ->
        {:retry, nil}
    end
  end

  defp account_active_movie_retry(movie) do
    attempts = (movie.search_attempts || 0) + 1

    if attempts >= @max_search_attempts do
      case guarded_movie_transition(movie, %{status: :search_failed}, movie.status) do
        {:ok, parked} ->
          intent_ids = Download.fence_movie_cleanup(parked, include_remote: false)
          {:parked, parked, intent_ids}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    else
      case guarded_movie_transition(
             movie,
             %{status: movie.status, search_attempts: attempts},
             movie.status
           ) do
        {:ok, updated} -> {:retry, updated}
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  # Transaction-safe state-change primitive: every guarded movie writer uses this exact changeset
  # and compare-and-swap update. It performs no publication, so callers publish only after their
  # encompassing transaction commits.
  defp guarded_movie_transition(movie, attrs, expected) do
    with %{valid?: true, changes: changes} <- Movie.transition_changeset(movie, attrs),
         {1, [updated]} <-
           Repo.update_all(
             from(m in Movie,
               where: m.id == ^movie.id and m.status == ^expected,
               select: m
             ),
             set: Map.to_list(changes) ++ [updated_at: now()]
           ) do
      {:ok, updated}
    else
      {0, _} -> {:error, :stale_status}
      %Ecto.Changeset{} = invalid -> {:error, invalid}
    end
  end

  defp publish_movie_intent_retry({:ok, {:retry, nil}}, _reason), do: :ok
  defp publish_movie_intent_retry({:ok, :stale_generation}, _reason), do: :ok

  defp publish_movie_intent_retry({:ok, {:retry, updated}}, _reason) do
    broadcast({:movie_updated, updated})
    :ok
  end

  defp publish_movie_intent_retry({:ok, {:parked, parked, intent_ids}}, reason) do
    broadcast({:movie_updated, parked})
    Notifier.notify({:movie_failed, parked, reason})
    Download.cleanup_intents(intent_ids)
    :ok
  end

  defp publish_movie_intent_retry({:error, reason}, _submission_reason), do: {:error, reason}

  defp run_guarded_movie_transition(
         movie,
         attrs,
         expected,
         after_update \\ fn _updated -> :ok end
       ) do
    Repo.transaction(fn ->
      case guarded_movie_transition(movie, attrs, expected) do
        {:ok, updated} ->
          after_update.(updated)
          updated

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @doc false
  def publish_guarded_movie_transition({:ok, updated}) do
    broadcast({:movie_updated, updated})
    {:ok, updated}
  end

  def publish_guarded_movie_transition({:error, reason}), do: {:error, reason}

  @doc "Updates a downloading movie's progress snapshot without broadcasting equal values."
  def update_movie_download_metrics(%Movie{} = movie, attrs) do
    changes = metric_changes(movie, attrs)

    if changes == %{} do
      {:ok, movie}
    else
      transition(movie, Map.put(changes, :status, movie.status), expect: movie.status)
    end
  end

  @doc "Updates an in-flight grab's progress snapshot and broadcasts its owning series."
  def update_grab_download_metrics(%Grab{} = grab, attrs) do
    changes = metric_changes(grab, attrs)

    if changes == %{} do
      if Repo.exists?(from(g in Grab, where: g.id == ^grab.id and is_nil(g.content_path))) do
        {:ok, grab}
      else
        {:error, :stale_grab}
      end
    else
      case Repo.update_all(
             from(g in Grab,
               where: g.id == ^grab.id and is_nil(g.content_path),
               select: g
             ),
             set: Map.to_list(changes) ++ [updated_at: now()]
           ) do
        {1, [updated]} ->
          broadcast_series(series_id_for_grab(grab.id))
          {:ok, updated}

        {0, _} ->
          {:error, :stale_grab}
      end
    end
  end

  defp metric_changes(record, attrs) do
    attrs = Map.take(attrs, @download_metric_fields)
    if Map.take(record, @download_metric_fields) == attrs, do: %{}, else: attrs
  end

  # Parked terminal states a user can re-queue. An in-flight movie must never be
  # yanked back to :requested, so retry guards on status server-side (the /status
  # button is a client-sent event — don't trust it to only fire for parked rows).
  @retryable [:no_match, :search_failed, :import_failed]

  @doc """
  Re-queues a parked movie: resets it to `:requested` and zeroes the attempt
  counters so the poller picks it up fresh. Returns `{:error, :not_retryable}`
  for any non-parked movie. Replaces the old IEx reset.
  """
  def retry_movie(%Movie{status: :import_failed, verification_hold_origin: origin} = movie)
      when origin in [:download, :upgrade] do
    status = if origin == :download, do: :downloaded, else: :upgrading

    ReleaseVerification.transition_verification_hold(movie, %{
      status: status,
      import_attempts: 0,
      verification_hold_origin: nil
    })
  end

  def retry_movie(%Movie{status: status} = movie) when status in @retryable do
    # Clear the stale download fields too: a re-queued movie has no download yet,
    # so leaving an old download_id/protocol/file_path/content_path/release_title on a
    # :requested row is misleading and a latent misroute if anything reads them before
    # re-download. The blocklist row (keyed by movie_id) PERSISTS — clearing it would
    # reintroduce the re-grab loop; release_title here is stale download state, not the blocklist.
    # expect: — the caller's struct is a client-rendered snapshot; if the movie
    # already re-entered the pipeline (re-searched, downloading), the retry must
    # miss rather than yank an in-flight movie back and orphan its download.
    transition(
      movie,
      %{
        status: :requested,
        search_attempts: 0,
        import_attempts: 0,
        download_id: nil,
        download_protocol: nil,
        release_title: nil,
        release_policy_snapshot: nil,
        file_path: nil,
        content_path: nil
      },
      expect: movie.status
    )
  end

  def retry_movie(%Movie{}), do: {:error, :not_retryable}

  @doc "Atomically parks an unverifiable Movie release without clearing its frozen ownership."
  defdelegate hold_movie_verification(movie, origin, attempts), to: ReleaseVerification

  @doc """
  Grabs a specific user-chosen `release` for `movie`. An `:available` movie enters `:upgrading`
  (its library `file_path` and `imported_*` are preserved — the poller's upgrade clause swaps the
  file only on a successful re-import). A parked movie (`#{inspect(@retryable)}`) enters
  `:downloading` on the normal import path. Any other status returns `{:error, :not_grabbable}`
  (rejecting in-flight/`:upgrading`/`:cancelled`, which also blocks a double-click). A movie deleted
  mid-action surfaces `{:error, :stale_entry}`.
  """
  def manual_grab_movie(%Movie{status: :available} = movie, %Release{} = release) do
    Download.grab_movie(movie, release)
  end

  def manual_grab_movie(
        %Movie{status: status, verification_hold_origin: nil} = movie,
        %Release{} = release
      )
      when status in @retryable do
    Download.grab_movie(movie, release)
  end

  def manual_grab_movie(%Movie{}, %Release{}), do: {:error, :not_grabbable}

  @doc """
  Grabs a user-chosen `release` for one `season_number` of `series`. Recomputes the season's
  still-wanted episodes server-side (don't trust a stale panel snapshot) and creates the grab over
  exactly the wanted episodes the release covers (`episodes: nil` = a whole-season pack covers them
  all). `create_grab/5` itself skips any episode that already has a grab, so a concurrent sweep grab
  can't be double-linked. `{:error, :nothing_wanted}` when the season has nothing to grab.
  """
  def manual_grab_tv(%Series{} = series, season_number, %Release{} = release) do
    case media_profile_summary(series).effective do
      :anime -> manual_grab_anime_tv(series, season_number, release)
      :standard -> manual_grab_standard_tv(series, season_number, release)
    end
  end

  defp manual_grab_anime_tv(
         %Series{id: series_id},
         season_number,
         %Release{} = release
       ) do
    wanted_ids =
      wanted_episodes()
      |> Enum.filter(
        &(&1.season.series.id == series_id and &1.season.season_number == season_number)
      )
      |> Enum.map(& &1.id)

    with true <- safe_anime_mapping?(release),
         true <- MapSet.subset?(MapSet.new(release.resolved_episode_ids), MapSet.new(wanted_ids)) do
      case grab_and_create_grab(release, release.resolved_episode_ids) do
        {:error, :invalid_mapping_snapshot} -> {:error, :unsafe_anime_mapping}
        result -> result
      end
    else
      false -> {:error, :unsafe_anime_mapping}
    end
  end

  defp safe_anime_mapping?(%Release{
         resolved_episode_ids: ids,
         mapping_snapshot: %{"version" => 2} = snapshot
       })
       when is_list(ids) and ids != [] do
    kind = if length(ids) == 1, do: :episode, else: :season_pack
    Intent.valid_mapping_snapshot?(snapshot, kind, ids)
  end

  defp safe_anime_mapping?(_release), do: false

  defp manual_grab_standard_tv(_series, _season_number, %Release{mapping_snapshot: snapshot})
       when not is_nil(snapshot),
       do: {:error, :unsafe_anime_mapping}

  defp manual_grab_standard_tv(%Series{id: series_id}, season_number, %Release{} = release) do
    wanted =
      wanted_episodes()
      |> Enum.filter(
        &(&1.season.series.id == series_id and &1.season.season_number == season_number)
      )

    covered = cover_numbers(release, Enum.map(wanted, & &1.episode_number))
    episode_ids = wanted |> Enum.filter(&(&1.episode_number in covered)) |> Enum.map(& &1.id)

    case episode_ids do
      [] -> {:error, :nothing_wanted}
      ids -> grab_and_create_grab(release, ids)
    end
  end

  # Grabs the release (a client.add side-effect returning a download_id), then links the grab over
  # `episode_ids`. If create_grab/5 rolls back — a concurrent sweep grabbed the episodes first
  # (:no_episodes_linked) or the insert failed — best-effort remove the just-added download so it
  # isn't orphaned in the client, then surface the error.
  defp grab_and_create_grab(%Release{} = release, episode_ids) do
    Download.grab_episodes(release, episode_ids)
  end

  # A whole-season pack (episodes: nil) covers every still-wanted number; an episode list covers its
  # intersection with what's wanted. Mirrors Scorer.coverage/2.
  defp cover_numbers(%Release{episodes: nil}, wanted_numbers), do: wanted_numbers

  defp cover_numbers(%Release{episodes: eps}, wanted_numbers),
    do: Enum.filter(wanted_numbers, &(&1 in eps))

  # Parked statuses where a language change should trigger a fresh search.
  # :import_failed means a release was found but couldn't be written — not a language issue.
  @language_retry_statuses [:no_match, :search_failed]

  # Plain field write shared by set_movie_language/2 and the approval-fill
  # (fill_movie_language/2, via apply_requester_language/3): language_changeset + Repo.update,
  # no status/retry side effects.
  defp write_movie_language(movie, language) do
    movie |> Movie.language_changeset(%{preferred_language: language}) |> Repo.update()
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  @doc """
  Sets a movie's preferred language. If the movie is parked because no release in
  the desired language was found, re-queues it so the poller re-searches. Otherwise
  just updates the field — the download/import pipeline is not disturbed for
  in-flight or available movies (no quality-upgrade re-grab in this slice).
  """
  def set_movie_language(%Movie{} = movie, language) do
    case write_movie_language(movie, language) do
      {:ok, updated} ->
        if updated.status in @language_retry_statuses do
          retry_movie(updated)
        else
          broadcast({:movie_updated, updated})
          {:ok, updated}
        end

      {:error, _changeset} = error ->
        error
    end
  end

  # Status-neutral pick fill for request approval (apply_requester_language/3, via
  # apply_confirmed_media/3): writes the field and broadcasts, WITHOUT set_movie_language/2's
  # retry branch — approving a request for an existing PARKED movie must not silently re-queue
  # it (round-3 finding 2).
  defp fill_movie_language(movie, language) do
    case write_movie_language(movie, language) do
      {:ok, updated} ->
        broadcast({:movie_updated, updated})
        {:ok, updated}

      {:error, _changeset} = error ->
        error
    end
  end

  @doc """
  Persists the probed media info (audio languages + embedded/sidecar subtitle languages) onto a
  movie or episode. Descriptive-only — used by the import capture and the backfill task; not a
  status transition.
  """
  def set_media_info(%Movie{} = movie, info) do
    with {:ok, updated} <-
           movie |> Movie.media_info_changeset(media_info_attrs(info)) |> Repo.update() do
      broadcast({:movie_updated, updated})
      {:ok, updated}
    end
  end

  def set_media_info(%Episode{} = episode, info) do
    with {:ok, updated} <-
           episode |> Episode.media_info_changeset(media_info_attrs(info)) |> Repo.update() do
      broadcast_series(series_id_for_season(updated.season_id))
      {:ok, updated}
    end
  end

  # Translate the bare-keyed capture map to the imported_* column names the changeset casts.
  defp media_info_attrs(info) do
    %{
      imported_audio_languages: Map.get(info, :audio_languages, []),
      imported_embedded_subtitles: Map.get(info, :embedded_subtitles, []),
      imported_sidecar_subtitles: Map.get(info, :sidecar_subtitles, [])
    }
  end

  @doc """
  Sets a series' preferred language and zeroes `search_attempts` on its still-wanted
  episodes (no file, no grab) so a previously language-stranded season re-enters the
  search sweep. Available / in-flight episodes are untouched.
  """
  def set_series_language(%Series{} = series, language) do
    result =
      Repo.transaction(fn ->
        case series
             |> Series.language_changeset(%{preferred_language: language})
             |> Repo.update() do
          {:ok, updated} ->
            from(e in Episode,
              join: s in Season,
              on: e.season_id == s.id,
              where:
                s.series_id == ^series.id and is_nil(e.file_path) and is_nil(e.grab_id) and
                  e.search_attempts > 0
            )
            |> Repo.update_all(set: [search_attempts: 0])

            updated

          # The row update + the episode reset are one transaction (mirroring
          # set_season_monitored/2): surface a write failure as {:error, changeset}, roll back.
          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    with {:ok, updated} <- result do
      broadcast_series(series.id)
      {:ok, updated}
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  # The active set a movie can be cancelled out of (mirrors @retryable's shape).
  # transition/2 does NOT validate transitions, so cancel/delete must guard on this
  # explicitly. delete_movie/2 (Phase 2) shares it: an active row with a download_id
  # must be cancelled (which removes the client download), never bare-deleted.
  @cancellable_movie_statuses [:requested, :searching, :downloading, :downloaded]

  @doc "True if `movie` is in an active status that can be cancelled (`#{inspect(@cancellable_movie_statuses)}`)."
  def cancellable?(%Movie{status: :import_failed, verification_hold_origin: :download}), do: true
  def cancellable?(%Movie{status: status}), do: status in @cancellable_movie_statuses

  @doc """
  Cancels an in-flight movie: removes the orphaned client download (if any) and transitions
  it to `:cancelled`. Guards `cancellable?/1` server-side (`transition/2` does not validate the
  transition). Returns `{:error, :not_cancellable}` for a terminal/available/parked movie.

  The `:cancelled` transition, audit row, and durable cleanup fence are written in one transaction.
  Client I/O runs only after commit; failures leave the fence for background reconciliation.
  """
  def cancel_movie(
        %Movie{status: :import_failed, verification_hold_origin: :download} = movie,
        actor
      ),
      do: ReleaseVerification.clear_verification_hold(movie, actor, :cancelled, :cancel_movie)

  def cancel_movie(%Movie{} = movie, actor) do
    if cancellable?(movie) do
      with {:ok, {updated, intent_ids}} <- do_cancel_txn(movie, actor) do
        Download.cleanup_intents(intent_ids)
        broadcast({:movie_updated, updated})
        {:ok, updated}
      end
    else
      {:error, :not_cancellable}
    end
  end

  defp do_cancel_txn(movie, actor) do
    Repo.transaction(fn ->
      case movie
           |> Movie.transition_changeset(%{status: :cancelled, release_policy_snapshot: nil})
           |> Repo.update() do
        {:ok, updated} ->
          updated = Repo.get!(Movie, updated.id)
          intent_ids = Download.fence_movie_cleanup(updated)
          Audit.log_or_rollback(actor, :cancel_movie, updated, %{from: movie.status})
          {updated, intent_ids}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Aborts an in-flight movie upgrade: removes the replacement download (best-effort) and reverts
  the movie to `:available`, keeping the existing library file. Distinct from `cancel_movie/2` —
  an `:upgrading` movie must NOT become `:cancelled` (it still has a good file). Returns
  `{:error, :not_upgrading}` otherwise.

  The `:available` revert, audit row, and durable cleanup fence are written in one transaction.
  Client I/O runs only after commit; failures leave the fence for background reconciliation.
  """
  def abort_upgrade(%Movie{status: :upgrading} = movie, actor) do
    result =
      Repo.transaction(fn ->
        cleanup_source = Repo.get!(Movie, movie.id)

        case cleanup_source
             |> Movie.transition_changeset(%{
               status: :available,
               download_id: nil,
               download_protocol: nil,
               release_title: nil,
               release_policy_snapshot: nil
             })
             |> Repo.update() do
          {:ok, updated} ->
            updated = Repo.get!(Movie, updated.id)
            intent_ids = Download.fence_movie_cleanup(cleanup_source)
            Audit.log_or_rollback(actor, :abort_upgrade, updated, %{from: :upgrading})
            {updated, intent_ids}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    with {:ok, {updated, intent_ids}} <- result do
      Download.cleanup_intents(intent_ids)
      broadcast({:movie_updated, updated})
      {:ok, updated}
    end
  end

  def abort_upgrade(
        %Movie{status: :import_failed, verification_hold_origin: :upgrade} = movie,
        actor
      ),
      do: ReleaseVerification.clear_verification_hold(movie, actor, :available, :abort_upgrade)

  def abort_upgrade(%Movie{}, _actor), do: {:error, :not_upgrading}

  @doc """
  Deletes a movie's DB row. An active row's tracked download is captured in a durable cleanup
  fence in the same transaction, then removed after commit. Broadcasts
  `{:movie_deleted, id}` on the `"movies"` topic. The delete + audit row are written in one
  transaction.

  Pass `delete_files: true` in `opts` to also unlink the on-disk library file after the row is
  deleted (best-effort: a failed unlink is logged, not propagated). Default leaves files on disk.
  """
  def delete_movie(%Movie{} = movie, actor, opts \\ []) do
    delete_files? = Keyword.get(opts, :delete_files, false)

    prepare = fn fresh ->
      include_remote? =
        cancellable?(fresh) or fresh.status == :upgrading or
          fresh.verification_hold_origin in [:download, :upgrade]

      Download.fence_movie_cleanup(fresh, include_remote: include_remote?)
    end

    with {:ok, {deleted, intent_ids}} <-
           delete_with_audit(movie, actor, :delete_movie, delete_files?, prepare) do
      Download.cleanup_intents(intent_ids)
      if delete_files?, do: best_effort_delete_file(movie.file_path)
      broadcast_movie_deleted(deleted.id)
      {:ok, deleted}
    end
  end

  # Deletes a movie or series row and writes the audit entry in one transaction; a concurrent
  # delete (Repo.delete/1 raises) becomes a clean {:error, :stale_entry}.
  defp delete_with_audit(record, actor, action, delete_files?, prepare) do
    Repo.transaction(fn ->
      module = record.__struct__

      case Repo.update_all(from(r in module, where: r.id == ^record.id), set: [updated_at: now()]) do
        {1, _} -> :ok
        {0, _} -> Repo.rollback(:stale_entry)
      end

      fresh = Repo.get!(module, record.id)
      prepared = prepare.(fresh)

      case Repo.delete(fresh) do
        {:ok, deleted} ->
          Audit.log_or_rollback(actor, action, deleted, %{
            title: deleted.title,
            files_deleted: delete_files?
          })

          {deleted, prepared}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  # Best-effort library-file unlink shared by the movie and series delete paths: a failed unlink is
  # logged, never propagated, so it can't strand the row delete. Always returns :ok.
  # ponytail: no nil clause here — Library.delete_file/1 already guards nil/"" and returns :ok.
  defp best_effort_delete_file(path) do
    case Library.delete_file(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("library file delete failed for #{inspect(path)}: #{inspect(reason)}")
        :ok
    end
  end

  @doc "Fetches a movie by TMDB id, or `nil`."
  def get_movie_by_tmdb_id(tmdb_id), do: Repo.get_by(Movie, tmdb_id: tmdb_id)

  @doc """
  Returns `{:ok, movie, :existing}` for the existing row (at its current status) if one
  already exists for `attrs.tmdb_id`, or `{:ok, movie, :created}` after inserting a new
  movie at `:requested`.

  No broadcast here — this may run inside a caller's transaction (a savepoint when joined
  to one already open), so announcing creation is the caller's post-commit job
  (`Cinder.Requests.finalize_movie_approval/2` broadcasts `{:movie_created, movie}` once
  its transaction has committed, using the returned `:created` marker).

  Confirm/fill (the requester's media-profile confirmation and language pick) is NOT applied
  here — `Cinder.Requests` calls `apply_confirmed_media/3` itself, after its approval
  transaction commits, so a fill/confirm failure can't roll back the atomic movie-creation +
  request-approval write. A fresh insert already carries both fields straight from `attrs`
  (`Movie.changeset/2` casts them), so nothing is lost for the create case.

  A lost insert race (unique_constraint on `:tmdb_id`) is handled by re-fetching the
  winner and returning it as `:existing`, so callers always get `{:ok, movie, marker}`.
  """
  def find_or_create_at_requested(attrs, aliases \\ []) do
    case get_movie_by_tmdb_id(attrs.tmdb_id) do
      %Movie{} = movie -> {:ok, movie, :existing}
      nil -> do_insert_at_requested(attrs, aliases)
    end
  end

  @doc "Fetches requested-movie details and aliases before any Catalog write."
  def prepare_requested_movie(attrs) do
    tmdb_id = Map.fetch!(attrs, :tmdb_id)

    case get_movie_by_tmdb_id(tmdb_id) do
      %Movie{} ->
        {:ok, %{attrs: attrs, aliases: []}}

      nil ->
        with {:ok, info} <- tmdb().get_movie(tmdb_id),
             {:ok, aliases} <- tmdb().get_movie_alternative_titles(info.tmdb_id) do
          create_attrs =
            info
            |> Map.take([
              :tmdb_id,
              :imdb_id,
              :title,
              :year,
              :poster_path,
              :original_language
            ])
            |> Map.merge(Map.take(attrs, [:preferred_language, :media_profile]))

          {:ok, %{attrs: create_attrs, aliases: aliases}}
        end
    end
  end

  defp do_insert_at_requested(attrs, aliases) do
    result =
      Repo.transaction(fn ->
        with {:ok, movie} <- %Movie{} |> Movie.changeset(attrs) |> Repo.insert(),
             {:ok, _aliases} <-
               Identity.replace_provider_aliases(
                 movie,
                 "tmdb",
                 "alternative_titles",
                 :inferred,
                 aliases
               ) do
          movie
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, movie} ->
        {:ok, movie, :created}

      {:error, reason} ->
        # Lost the insert race (unique_constraint :tmdb_id) — the row now exists.
        case get_movie_by_tmdb_id(attrs.tmdb_id) do
          %Movie{} = movie -> {:ok, movie, :existing}
          nil -> {:error, reason}
        end
    end
  end

  @doc """
  Shared confirm+fill sequence for an EXISTING movie or series matched by a request approval:
  fills the requester's language pick (if still default), then confirms the requester's
  media-profile proposal (:auto → confirmed only). Order is fill-then-confirm, not the reverse:
  a failed confirm after a successful fill just leaves a plain fill-if-default — benign, and
  a retry (the series path's re-approval, or a movie detail-page edit) picks up where it left
  off; confirm-then-fill would instead leave a committed profile flip with no clean retry
  surface if the fill then failed.

  Call this OUTSIDE any surrounding `Repo.transaction` — `Cinder.Requests` calls it after its
  approval transaction commits, so a fill/confirm failure here can't roll back an already-
  committed movie/request write. On the movie path a failure is logged (the request stays
  approved; both fields remain detail-page-editable); on the series path the caller propagates
  the error so the season approval reverts to pending (on the auto-approve path there is no
  approval to revert — the request is simply never created).
  """
  def apply_confirmed_media(media, profile, preferred) do
    pre_request_profile = media.media_profile

    with {:ok, media} <- apply_requester_language(media, preferred, pre_request_profile) do
      apply_confirmed_profile(media, profile)
    end
  end

  defp apply_confirmed_profile(%{media_profile: :auto} = media, profile)
       when profile in [:standard, :anime],
       do: set_media_profile(media, profile)

  defp apply_confirmed_profile(media, _profile), do: {:ok, media}

  @doc false
  def broadcast(message), do: Phoenix.PubSub.broadcast(Cinder.PubSub, @topic, message)

  @doc "Broadcasts `{:movie_deleted, id}` on the `\"movies\"` topic so open views drop the row."
  def broadcast_movie_deleted(id), do: broadcast({:movie_deleted, id})

  @doc "Broadcasts `{:movie_created, movie}` on the `\"movies\"` topic — called by `Cinder.Requests` after its approval transaction commits (the Catalog insert itself never broadcasts, see `find_or_create_at_requested/2`)."
  def broadcast_movie_created(%Movie{} = movie), do: broadcast({:movie_created, movie})

  ## TV series (M4a) — admin-only direct add; movie loop untouched.
  #
  # No PubSub topic yet: nothing subscribes until the M4b series-detail LiveView.
  # The whole tree inserts in one Repo.insert (= one transaction = one writer, so
  # WAL + busy_timeout stays correct).

  @doc """
  Adds a TV series and its season/episode tree, fetched from TMDB, flagging episodes
  `monitored` per `monitor_strategy` (`:all` / `:future` / `:none`; default `:future`).

  Find-or-create by `tmdb_id`: an already-added series is returned as-is; re-sync is
  `refresh_series/1` (the periodic Refresher). Returns `{:ok, series}` (associations unloaded — preload
  `[seasons: :episodes]` to read the tree), `{:error, :invalid_monitor_strategy}` for an
  unknown strategy, or `{:error, reason}` if a TMDB fetch fails.
  """
  def add_series(tmdb_id, opts \\ []) do
    strategy = Keyword.get(opts, :monitor_strategy, :future)

    # Validate at the boundary: the strategy drives monitored?/3 (a function-clause match)
    # *before* the Ecto.Enum changeset would catch it, so an unknown atom would otherwise
    # crash rather than return a clean error.
    preferred = Keyword.get(opts, :preferred_language, "original")
    media_profile = Keyword.get(opts, :media_profile, :auto)

    if strategy in Series.monitor_strategies() do
      case get_series_by_tmdb_id(tmdb_id) do
        %Series{} = series -> {:ok, series}
        nil -> create_series(tmdb_id, strategy, preferred, media_profile)
      end
    else
      {:error, :invalid_monitor_strategy}
    end
  end

  @doc """
  Request-approval entry for TV: find-or-create the series tree (from TMDB, nothing monitored
  on first create) and monitor **only** `season_number` (cascading to its episodes), leaving other
  seasons untouched. Sets `series.monitored: true`. Idempotent and additive across seasons.

  Does TMDB I/O on first create, so it must NOT be called inside a `Repo.transaction`.
  Returns `{:ok, %Series{}}`, or `{:error, reason}` if the TMDB fetch fails or the season is absent.
  """
  def find_or_create_series_at_requested(
        tmdb_id,
        season_number,
        preferred \\ "original",
        media_profile \\ :auto
      )

  def find_or_create_series_at_requested(tmdb_id, season_number, preferred, media_profile)
      when media_profile in [:auto, :standard, :anime] do
    with {:ok, series} <- ensure_series(tmdb_id, preferred, media_profile),
         {:ok, series} <- apply_confirmed_media(series, media_profile, preferred),
         %Season{} = season <- season_in(series, season_number),
         {:ok, _} <- set_season_monitored(season, true),
         {:ok, updated} <- mark_series_monitored(series) do
      {:ok, updated}
    else
      nil -> {:error, :season_not_found}
      {:error, _} = err -> err
    end
  end

  def find_or_create_series_at_requested(_tmdb_id, _season_number, _preferred, _media_profile),
    do: {:error, :invalid_media_profile}

  # Create with monitor_strategy: :none so NOTHING is monitored by default; the requested season
  # is then flipped on explicitly. An existing series is returned as-is.
  defp ensure_series(tmdb_id, preferred, media_profile),
    do:
      add_series(tmdb_id,
        monitor_strategy: :none,
        preferred_language: preferred,
        media_profile: media_profile
      )

  # Fill-if-default: an existing movie/series whose language was never customized ("original")
  # adopts the requester's non-default pick; a title already customized to a non-default is left
  # untouched (first-customization-wins). A brand-new movie/series already carries `preferred`
  # from its creation attrs/changeset.
  #
  # Guarded on the title's PRE-REQUEST profile (captured by apply_confirmed_media/3 before this
  # or apply_confirmed_profile/2 runs), not its post-confirmation profile: the request that
  # establishes Anime also establishes its audio policy (the pick), while a title that was
  # ALREADY Anime before this request never has its pick mutated — that pick is that title's
  # release policy (audio-mode derivation, see `Cinder.Acquisition.AnimePreferences`), not a
  # discovery convenience, so only a deliberate detail-page edit may change it once a title is
  # Anime.
  #
  # The movie clause fills through fill_movie_language/2 (status-neutral), not
  # set_movie_language/2 — an approval fill must not re-queue a parked movie.
  #
  # One guard for both clauses — these drifted once (the series clause lacked the nil
  # exclusion), so they are deliberately not hand-synced twins anymore.
  defguardp fillable_pick(preferred, pre_request_profile)
            when preferred not in [nil, "original"] and pre_request_profile != :anime

  defp apply_requester_language(
         %Series{preferred_language: "original"} = series,
         preferred,
         pre_request_profile
       )
       when fillable_pick(preferred, pre_request_profile),
       do: set_series_language(series, preferred)

  defp apply_requester_language(
         %Movie{preferred_language: "original"} = movie,
         preferred,
         pre_request_profile
       )
       when fillable_pick(preferred, pre_request_profile),
       do: fill_movie_language(movie, preferred)

  defp apply_requester_language(media, _preferred, _pre_request_profile), do: {:ok, media}

  defp season_in(series, season_number) do
    Repo.get_by(Season, series_id: series.id, season_number: season_number)
  end

  defp mark_series_monitored(series) do
    series |> Ecto.Changeset.change(monitored: true) |> Repo.update()
  end

  @doc "Fetches a series by TMDB id, or `nil`."
  def get_series_by_tmdb_id(tmdb_id), do: Repo.get_by(Series, tmdb_id: tmdb_id)

  @doc "Lists series, newest first."
  def list_series, do: Repo.all(from s in Series, order_by: [desc: s.id])

  @doc "Number of series in the catalog."
  def count_series, do: Repo.aggregate(Series, :count)

  @doc """
  Admin metadata edit for a series. Uses `Series.admin_changeset/2`, which excludes
  `monitor_strategy`/`monitored` so the edit never cascades a strategy change to existing
  seasons/episodes. Per-season/episode monitoring stays on `set_season_monitored/2` /
  `set_episode_monitored/2`. On success broadcasts `{:series_updated, series.id}` so other
  subscribed sessions refresh. Returns `{:ok, series}` or `{:error, changeset}`.
  """
  def update_series(%Series{} = series, attrs) do
    with {:ok, updated} <- series |> Series.admin_changeset(attrs) |> Repo.update() do
      broadcast_series(updated.id)
      {:ok, updated}
    end
  end

  defp create_series(tmdb_id, strategy, preferred, media_profile) do
    with {:ok, info} <- tmdb().get_series(tmdb_id),
         {:ok, seasons} <- fetch_seasons(tmdb_id, info.seasons),
         # A brand-new series has no scene_numbering_group_id yet (create_changeset doesn't
         # cast it), so there's nothing to pre-fetch here.
         {:ok, identity} <- fetch_series_identity(tmdb_id, nil) do
      insert_series(
        tmdb_id,
        series_attrs(info, seasons, strategy, preferred, media_profile),
        seasons,
        identity
      )
    end
  end

  defp insert_series(tmdb_id, attrs, seasons, identity) do
    result =
      Repo.transaction(fn ->
        with {:ok, series} <- attrs |> Series.create_changeset() |> Repo.insert(),
             :ok <- sync_series_identity(series, seasons, identity) do
          series
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, series} ->
        # Return the re-read row (not the cast_assoc result) so every add path —
        # found-existing, freshly-inserted, race-loss — returns a series with its
        # associations unloaded. Callers preload [seasons: :episodes] to read the tree.
        # Fall back to the inserted struct if the re-read somehow misses, so the
        # contract stays {:ok, %Series{}} and never {:ok, nil}.
        {:ok, get_series_by_tmdb_id(tmdb_id) || series}

      {:error, reason} ->
        # A unique_constraint(:tmdb_id) race rolls the whole tree back (no partial
        # rows), so the winner now exists — return it. Any other changeset error
        # finds no winner and propagates unchanged.
        case get_series_by_tmdb_id(tmdb_id) do
          %Series{} = series -> {:ok, series}
          nil -> {:error, reason}
        end
    end
  end

  # Fetch each season's episodes, short-circuiting on the first TMDB error so a
  # partial tree is never persisted.
  defp fetch_seasons(tmdb_id, season_stubs) do
    result =
      Enum.reduce_while(season_stubs, {:ok, []}, fn %{season_number: n}, {:ok, acc} ->
        case tmdb().get_season(tmdb_id, n) do
          {:ok, season} -> {:cont, {:ok, [season | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    with {:ok, seasons} <- result, do: {:ok, Enum.reverse(seasons)}
  end

  # `scene_numbering_group_id` is the series' operator-chosen scene group, or `nil` (a
  # brand-new series, or one with no alternate numbering configured). Its detail is fetched
  # here — alongside the rest of the identity data — so every TMDB call this function makes
  # happens before the caller's transaction opens (see `set_scene_numbering_group/2`'s own
  # pre-transaction fetch for the interactive-save path). `scene_group_fetched_for` records which
  # group id the detail belongs to, so the refresh transaction can tell whether a racing save
  # changed the group in between (`sync_scene_coordinates_if_current/2`).
  defp fetch_series_identity(tmdb_id, scene_numbering_group_id) do
    with {:ok, aliases} <- tmdb().get_series_alternative_titles(tmdb_id),
         {:ok, groups} <- tmdb().get_episode_groups(tmdb_id),
         {:ok, absolute_groups} <- fetch_absolute_groups(groups) do
      {:ok,
       %{
         aliases: aliases,
         absolute_groups: absolute_groups,
         scene_group_detail: fetch_scene_group_detail(scene_numbering_group_id),
         scene_group_fetched_for: scene_numbering_group_id
       }}
    end
  end

  defp fetch_scene_group_detail(nil), do: nil

  defp fetch_scene_group_detail(group_id) do
    case tmdb().get_episode_group(group_id) do
      {:ok, detail} ->
        detail

      {:error, reason} ->
        Logger.warning("scene numbering: group #{group_id} fetch failed: #{inspect(reason)}")
        nil
    end
  end

  defp fetch_absolute_groups(groups) do
    groups
    |> Enum.filter(&(&1.type == 2))
    |> Enum.reduce_while({:ok, []}, fn group, {:ok, details} ->
      case tmdb().get_episode_group(group.id) do
        {:ok, detail} -> {:cont, {:ok, [detail | details]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, details} -> {:ok, Enum.reverse(details)}
      error -> error
    end
  end

  defp sync_series_identity(series, seasons, identity) do
    with {:ok, _} <-
           Identity.replace_provider_aliases(
             series,
             "tmdb",
             "alternative_titles",
             :inferred,
             identity.aliases
           ),
         :ok <- sync_absolute_coordinates(series, identity.absolute_groups),
         :ok <- sync_scene_coordinates_if_current(series, identity),
         {:ok, _} <- sync_tmdb_classifications(series, seasons) do
      :ok
    end
  end

  # `identity.scene_group_detail` was fetched for `identity.scene_group_fetched_for` — read
  # before this refresh's transaction opened (TMDB is HTTP, never called inside a transaction).
  # `series` here is the transaction's own fresh re-read, so if a racing save changed the group in
  # between, the two ids differ: the detail belongs to a namespace `series` no longer points at,
  # and syncing it now would write the OLD group's entries under the NEW (racing save's)
  # namespace. Skip and keep whatever the racing save already wrote — never guess.
  defp sync_scene_coordinates_if_current(series, identity) do
    if series.scene_numbering_group_id == identity.scene_group_fetched_for do
      sync_scene_coordinates(series, identity.scene_group_detail)
    else
      Logger.info(
        "scene numbering: series #{series.id} group changed from " <>
          "#{inspect(identity.scene_group_fetched_for)} to " <>
          "#{inspect(series.scene_numbering_group_id)} mid-refresh, skipping scene sync"
      )

      :ok
    end
  end

  defp sync_absolute_coordinates(series, absolute_groups) do
    episode_ids =
      Repo.all(
        from e in Episode,
          join: season in assoc(e, :season),
          where: season.series_id == ^series.id and not is_nil(e.tmdb_episode_id),
          select: {e.tmdb_episode_id, e.id}
      )
      |> Map.new()

    details_by_namespace = Map.new(absolute_groups, &{&1.id, &1})

    existing_namespaces =
      Repo.all(
        from c in EpisodeCoordinate,
          where: c.series_id == ^series.id and c.source == "tmdb" and c.scheme == "absolute",
          select: c.namespace,
          distinct: true
      )

    (existing_namespaces ++ Map.keys(details_by_namespace))
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn namespace, :ok ->
      coordinates =
        details_by_namespace
        |> Map.get(namespace)
        |> absolute_coordinate_attrs(episode_ids)

      case Identity.replace_provider_coordinates(
             series,
             "tmdb",
             namespace,
             "absolute",
             coordinates
           ) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp absolute_coordinate_attrs(nil, _episode_ids), do: []

  defp absolute_coordinate_attrs(group, episode_ids) do
    entries = Enum.sort_by(group.entries, &{&1.group_order, &1.order})

    if Enum.all?(entries, &Map.has_key?(episode_ids, &1.tmdb_episode_id)) do
      entries
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, absolute_number} ->
        %{
          scheme: "absolute",
          canonical_value: Integer.to_string(absolute_number),
          precedence: :inferred,
          episode_ids: [Map.fetch!(episode_ids, entry.tmdb_episode_id)]
        }
      end)
    else
      []
    end
  end

  # Mirrors sync_absolute_coordinates/2's shape, but is a distinct writer: the operator picks
  # one specific group (`series.scene_numbering_group_id`), not "every type-2 group TMDB has."
  # `detail` is the already-fetched TMDB episode-group detail — fetched by the caller before
  # any transaction opens (`fetch_scene_group_detail/1`, threaded through
  # `set_scene_numbering_group/2` and `fetch_series_identity/2`), never inside one: TMDB is a
  # live HTTP call, and running it under an open SQLite write transaction risks a concurrent
  # writer tripping the busy_timeout. `nil` means "not configured" or "the fetch failed" — a
  # failed fetch (already logged by the caller) keeps whatever scene rows are already synced,
  # never strips them.
  defp sync_scene_coordinates(%Series{scene_numbering_group_id: nil}, _detail), do: :ok
  defp sync_scene_coordinates(%Series{}, nil), do: :ok

  defp sync_scene_coordinates(%Series{scene_numbering_group_id: group_id} = series, detail) do
    episode_lookup =
      Repo.all(
        from e in Episode,
          join: season in assoc(e, :season),
          where: season.series_id == ^series.id and not is_nil(e.tmdb_episode_id),
          select: {e.tmdb_episode_id, e.id, season.season_number, e.episode_number}
      )
      |> Map.new(fn {tmdb_episode_id, id, season_number, episode_number} ->
        {tmdb_episode_id, %{id: id, season_number: season_number, episode_number: episode_number}}
      end)

    coordinates = scene_coordinate_attrs(series, detail, episode_lookup)

    case Identity.replace_provider_coordinates(series, "tmdb", group_id, "scene", coordinates) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Unlike absolute_coordinate_attrs/2 (all-or-nothing), a scene entry with no matching episode
  # row is skipped and logged rather than voiding the whole sync — TMDB's specials subgroup
  # commonly lists episodes Cinder never imported (season 0 outside the main tree), and that
  # must not block the season split the operator actually chose the group for. Shares its
  # per-entry derivation with preview_scene_mapping/2 via derive_scene_entries/2, so Save can
  # never persist something different from what the picker previewed.
  defp scene_coordinate_attrs(series, group, episode_lookup) do
    group.entries
    |> derive_scene_entries(episode_lookup)
    |> Enum.flat_map(fn
      %{matched: nil, ambiguous: true, tmdb_episode_id: tmdb_episode_id} ->
        Logger.warning(
          "scene numbering: series #{series.id} group #{group.id} entry " <>
            "tmdb_episode_id=#{tmdb_episode_id} is claimed by more than one subgroup, " <>
            "dropping rather than guessing"
        )

        []

      %{matched: nil, tmdb_episode_id: tmdb_episode_id} ->
        Logger.warning(
          "scene numbering: series #{series.id} group #{group.id} entry " <>
            "tmdb_episode_id=#{tmdb_episode_id} matches no episode row, skipping"
        )

        []

      %{matched: matched, season_number: season_number, episode_number: episode_number} ->
        [
          %{
            scheme: "scene",
            canonical_value: Episode.code(season_number, episode_number),
            precedence: :inferred,
            episode_ids: [matched.id]
          }
        ]
    end)
  end

  # The per-entry derivation shared by scene_coordinate_attrs/3 (persists) and
  # preview_scene_mapping/2 (display-only), so the picker's preview can never drift from what
  # Save actually writes. `episode_lookup` maps tmdb_episode_id => %{id:, season_number:,
  # episode_number:} for the matched Cinder episode (built differently by each caller — a DB
  # query in the write path, the caller's preloaded tree in the preview path — but shaped
  # identically).
  #
  # A Story Arc-shaped group (type 5) can legitimately place the same episode in two subgroups —
  # two entries sharing one tmdb_episode_id, with two different derived season/episode numbers.
  # There's no safe way to pick one, so an episode claimed by more than one entry has ALL of its
  # entries dropped (`matched: nil, ambiguous: true`) rather than guessing; they fall into the
  # unmatched/skipped side on both the write path and the preview.
  defp derive_scene_entries(entries, episode_lookup) do
    mapped =
      Enum.map(entries, fn entry ->
        {season_number, season_source} = scene_season_number(entry)

        %{
          tmdb_episode_id: entry.tmdb_episode_id,
          season_number: season_number,
          season_source: season_source,
          group_name: entry.group_name,
          episode_number: entry.order + 1,
          matched: Map.get(episode_lookup, entry.tmdb_episode_id),
          ambiguous: false
        }
      end)

    duplicated_ids =
      mapped
      |> Enum.frequencies_by(& &1.tmdb_episode_id)
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> MapSet.new(fn {id, _count} -> id end)

    Enum.map(mapped, fn entry ->
      if MapSet.member?(duplicated_ids, entry.tmdb_episode_id) do
        %{entry | matched: nil, ambiguous: true}
      else
        entry
      end
    end)
  end

  # The derived season for one flattened group entry: parse the subgroup's own name when it
  # says so unambiguously ("Season 2", "2nd Season", "Specials"), else fall back to the
  # subgroup's `order` (every probed group has Specials at order 0 and "Season N" at order N —
  # see the A6 design doc's probe results). Returns `{season_number, season_source}` —
  # `season_source` (`:name` | `:order`) records which path won, so a UI can flag an
  # order-derived season (a convention, not an API guarantee) by showing the raw subgroup name.
  # Consumed by derive_scene_entries/2.
  defp scene_season_number(%{group_name: name, group_order: order}) do
    case parse_subgroup_season(name) do
      {:ok, season} -> {season, :name}
      :error -> {order, :order}
    end
  end

  defp parse_subgroup_season(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      Regex.match?(~r/^specials?$/i, trimmed) ->
        {:ok, 0}

      match = Regex.run(~r/^season\s+(\d+)$/i, trimmed) ->
        {:ok, match |> Enum.at(1) |> String.to_integer()}

      match = Regex.run(~r/^(\d+)(?:st|nd|rd|th)\s+season$/i, trimmed) ->
        {:ok, match |> Enum.at(1) |> String.to_integer()}

      true ->
        :error
    end
  end

  defp parse_subgroup_season(_name), do: :error

  defp sync_tmdb_classifications(series, seasons) do
    episode_ids =
      Repo.all(
        from e in Episode,
          join: season in assoc(e, :season),
          where: season.series_id == ^series.id and not is_nil(e.tmdb_episode_id),
          select: {e.tmdb_episode_id, e.id}
      )
      |> Map.new()

    classifications =
      for season <- seasons,
          episode <- season.episodes,
          episode_id = episode_ids[episode.tmdb_episode_id],
          not is_nil(episode_id) do
        {classification, label} =
          Identity.classify_tmdb_episode(season.season_number, episode.title)

        {episode_id, classification, label}
      end

    Identity.put_provider_classifications("tmdb", classifications)
  end

  defp series_attrs(info, seasons, strategy, preferred, media_profile) do
    today = Date.utc_today()

    %{
      tmdb_id: info.tmdb_id,
      tvdb_id: info.tvdb_id,
      title: info.title,
      year: info.year,
      poster_path: info.poster_path,
      original_language: info[:original_language],
      preferred_language: preferred,
      overview: Map.get(info, :overview),
      genres: Map.get(info, :genres),
      vote_average: Map.get(info, :vote_average),
      first_air_date: Map.get(info, :first_air_date),
      media_profile: media_profile,
      monitored: strategy != :none,
      monitor_strategy: strategy,
      seasons:
        for season <- seasons do
          %{
            season_number: season.season_number,
            monitored: strategy != :none,
            episodes:
              for ep <- season.episodes do
                provider_episode_attrs(ep, season.season_number, strategy, today)
              end
          }
        end
    }
  end

  defp provider_episode_attrs(ep, season_number, strategy, today) do
    {classification, label} = Identity.classify_tmdb_episode(season_number, ep.title)

    ep
    |> Map.put(:classification, classification)
    |> Map.put(:classification_source, "tmdb")
    |> Map.put(:classification_label, label)
    |> Map.put(
      :monitored,
      classification == :regular and monitored?(strategy, ep.air_date, today)
    )
  end

  # Strategy applies to regular episodes. Provider-classified specials start unmonitored and
  # require an explicit operator toggle. `:future` treats undated/TBA regular episodes as
  # monitored and counts "today" as eligible.
  defp monitored?(:all, _air_date, _today), do: true
  defp monitored?(:none, _air_date, _today), do: false
  defp monitored?(:future, nil, _today), do: true
  defp monitored?(:future, air_date, today), do: Date.compare(air_date, today) != :lt

  ## TV monitoring toggles + the "series" topic (M4b).
  #
  # Monitor flags are NOT pipeline state, so they don't go through `transition/2` (that's the
  # movie-status choke-point): each setter is its own single-writer with its own broadcast. The
  # "series" topic carries only `{:series_updated, series_id}` — the series-detail LiveView
  # subscribes so a second open tab reflects a toggle. No TV poller writes out-of-band yet (M5),
  # so nothing else needs it.

  @series_topic "series"

  @doc "Subscribes the caller to series-change broadcasts (`{:series_updated, series_id}`)."
  def subscribe_series, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @series_topic)

  @doc """
  Loads a series with its seasons (ordered by `season_number`) and each season's episodes
  (ordered by `episode_number`), or `nil` for a missing id.
  """
  def get_series_with_tree(id) do
    case Repo.get(Series, id) do
      nil ->
        nil

      series ->
        seasons_q = from(s in Season, order_by: s.season_number)

        memberships_q =
          from(m in Cinder.Catalog.EpisodeCoordinateMembership,
            order_by: m.position,
            preload: [:episode_coordinate]
          )

        eps_q =
          from(e in Episode,
            order_by: e.episode_number,
            preload: [coordinate_memberships: ^memberships_q]
          )

        Repo.preload(series, seasons: {seasons_q, [episodes: eps_q]})
    end
  end

  @doc "Sets one episode's `monitored` flag and broadcasts `{:series_updated, series_id}`."
  def set_episode_monitored(%Episode{} = episode, monitored?) do
    with {:ok, episode} <-
           episode |> Ecto.Changeset.change(monitored: monitored?) |> Repo.update() do
      broadcast_series(series_id_for_season(episode.season_id))
      {:ok, episode}
    end
  end

  @doc """
  Sets a season's `monitored` flag and cascades it to every episode in one transaction, then
  broadcasts `{:series_updated, series_id}`.
  """
  def set_season_monitored(%Season{} = season, monitored?) do
    result =
      Repo.transaction(fn ->
        case season |> Ecto.Changeset.change(monitored: monitored?) |> Repo.update() do
          {:ok, season} ->
            Repo.update_all(from(e in Episode, where: e.season_id == ^season.id),
              set: [monitored: monitored?, updated_at: now()]
            )

            season

          # Surface a write failure as {:error, changeset} (mirroring set_episode_monitored)
          # rather than raising — the cascade is one transaction, so roll the whole thing back.
          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    with {:ok, season} <- result do
      broadcast_series(season.series_id)
      {:ok, season}
    end
  end

  @doc """
  Single choke-point for episode **pipeline** writes (`file_path`, `grab_id`, attempt
  counters — no status enum; episode state is derived). On success broadcasts
  `{:series_updated, series_id}` on the `"series"` topic. `monitored` is NOT written here —
  it is not pipeline state and keeps `set_episode_monitored/2`.
  """
  def transition_episode(%Episode{} = episode, attrs) do
    with {:ok, updated} <- episode |> Episode.transition_changeset(attrs) |> Repo.update() do
      broadcast_series(series_id_for_season(updated.season_id))
      {:ok, updated}
    end
  end

  @doc """
  Deletes one episode's library file (Sonarr "delete episode file"): unlinks the file, then clears
  `file_path` so the episode reverts to its derived missing state — left monitored (the poller
  re-grabs next tick) unless `opts[:unmonitor]` also flips `monitored` off. A multi-episode file
  is shared, so its other episode rows are cleared too. The DB write + audit run in one transaction
  (mirroring `cancel_movie/2`); broadcasts `{:series_updated, series_id}` after commit. Returns
  `{:error, :no_file}` when there is no file, or the unlink's `{:error, reason}`
  (the DB is then untouched — the file is the whole point, so the error is surfaced, not best-effort).
  Ordering caveat: the unlink runs before the DB txn, so a (rare) txn failure after a successful
  unlink leaves `file_path` pointing at a now-deleted file (the episode reads falsely-available)
  until re-deleted — recoverable because `rm` of a missing file is idempotent (`:enoent` → `:ok`).
  """
  def delete_episode_file(episode, actor, opts \\ [])

  def delete_episode_file(%Episode{file_path: p}, _actor, _opts) when p in [nil, ""],
    do: {:error, :no_file}

  def delete_episode_file(%Episode{} = episode, actor, opts) do
    unmonitor? = Keyword.get(opts, :unmonitor, false)

    with :ok <- Library.delete_file(episode.file_path),
         {:ok, updated} <- do_delete_episode_file_txn(episode, actor, unmonitor?) do
      broadcast_series(series_id_for_season(updated.season_id))
      {:ok, updated}
    end
  end

  defp do_delete_episode_file_txn(episode, actor, unmonitor?) do
    Repo.transaction(fn ->
      changeset =
        episode
        |> Episode.transition_changeset(%{
          file_path: nil,
          # Zero the counter so a previously search-parked episode really is
          # re-grabbed next tick, as the docstring promises.
          search_attempts: 0,
          imported_resolution: nil,
          imported_size: nil,
          imported_language: nil,
          imported_source: nil,
          imported_audio_languages: nil,
          imported_embedded_subtitles: nil,
          imported_sidecar_subtitles: nil
        })
        |> maybe_unmonitor(unmonitor?)

      case Repo.update(changeset) do
        {:ok, updated} ->
          clear_shared_file_paths(episode.file_path)
          Audit.log_or_rollback(actor, :delete_episode_file, updated, %{unmonitored: unmonitor?})
          updated

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  defp clear_shared_file_paths(path) do
    Repo.update_all(from(e in Episode, where: e.file_path == ^path),
      set: [
        file_path: nil,
        search_attempts: 0,
        imported_resolution: nil,
        imported_size: nil,
        imported_language: nil,
        imported_source: nil,
        imported_audio_languages: nil,
        imported_embedded_subtitles: nil,
        imported_sidecar_subtitles: nil,
        updated_at: now()
      ]
    )
  end

  defp maybe_unmonitor(changeset, true),
    do: Ecto.Changeset.put_change(changeset, :monitored, false)

  defp maybe_unmonitor(changeset, false), do: changeset

  @doc """
  Deletes every library file in a season (Sonarr per-season "delete episode files"): unlinks each
  episode's file (best-effort, per file), then clears `file_path` — and `monitored` off on
  `opts[:unmonitor]` — for the episodes whose file was actually removed, in ONE transaction + ONE
  `{:series_updated, _}` broadcast (mirrors `set_season_monitored/2`). A per-file unlink failure is
  logged and that episode keeps its `file_path` (so it isn't falsely marked missing). Returns
  `{:ok, cleared_count, failed_count}` where `failed_count` is the number of episodes whose unlink
  returned `{:error, _}` (callers should warn the user when `failed_count > 0`).
  """
  def delete_season_files(%Season{} = season, actor, opts \\ []) do
    unmonitor? = Keyword.get(opts, :unmonitor, false)

    # Bulk path mirrors set_season_monitored/2: the txn writes file_path/monitored via update_all
    # (NOT Episode.transition_changeset — file_path: nil has no validation to enforce), and the
    # read-then-write window (episodes read, files unlinked, then update_all) is the same one
    # set_season_monitored carries. Accepted at household scale (WAL + busy_timeout serializes the
    # writes; worst case a just-imported file is re-cleared and the user re-deletes).
    episodes =
      Repo.all(from e in Episode, where: e.season_id == ^season.id and not is_nil(e.file_path))

    results = Enum.map(episodes, fn ep -> {ep, Library.delete_file(ep.file_path)} end)
    cleared_ids = for {ep, :ok} <- results, do: ep.id
    failed_count = Enum.count(results, fn {_ep, r} -> r != :ok end)

    for {ep, {:error, reason}} <- results do
      Logger.warning(
        "library file delete failed for #{inspect(ep.file_path)}: #{inspect(reason)}"
      )
    end

    with {:ok, _} <- do_delete_season_files_txn(season, actor, cleared_ids, unmonitor?) do
      broadcast_series(season.series_id)
      {:ok, length(cleared_ids), failed_count}
    end
  end

  defp do_delete_season_files_txn(season, actor, cleared_ids, unmonitor?) do
    Repo.transaction(fn ->
      sets =
        [
          file_path: nil,
          # Zero the counter so previously search-parked episodes really are
          # re-grabbed next tick, as the docstring promises.
          search_attempts: 0,
          imported_resolution: nil,
          imported_size: nil,
          imported_language: nil,
          imported_source: nil,
          imported_audio_languages: nil,
          imported_embedded_subtitles: nil,
          imported_sidecar_subtitles: nil,
          updated_at: now()
        ] ++ if(unmonitor?, do: [monitored: false], else: [])

      Repo.update_all(from(e in Episode, where: e.id in ^cleared_ids), set: sets)

      Audit.log_or_rollback(actor, :delete_season_files, season, %{
        count: length(cleared_ids),
        unmonitored: unmonitor?
      })

      season
    end)
  end

  @doc false
  def now, do: DateTime.truncate(DateTime.utc_now(), :second)

  @doc """
  Creates a grab for `episode_ids` (a non-empty list of episodes in one series — a single
  episode or a season pack) and links them in one transaction, then broadcasts
  `{:series_updated, series_id}`. `release_title` (optional) records the chosen release's name
  on the grab so the blocklist can skip it if this download later parks. A changeset failure
  (e.g. a missing `download_id`) rolls the whole thing back as `{:error, changeset}` rather than
  raising, mirroring `set_season_monitored/2`.

  `opts` — `reset_attempts: true` zeroes the linked episodes' `search_attempts` in the same
  transaction (the manual-grab path uses it, mirroring `manual_grab_movie/2`): the user-chosen
  release gets a fresh search budget, and new grabs never carry a counter at/above the cap.
  """
  def create_grab(download_id, protocol, episode_ids, release_title \\ nil, opts \\ []) do
    result =
      Repo.transaction(fn ->
        insert_and_link_grab(download_id, protocol, episode_ids, release_title, opts)
      end)

    with {:ok, grab} <- result do
      broadcast_grab_series(grab)
      {:ok, grab}
    end
  end

  @doc "Atomically transfers an anime intent's frozen mapping snapshot and episode ownership."
  def create_grab_from_intent(%Cinder.Download.Intent{} = intent) do
    result =
      Repo.transaction(fn ->
        fresh = Repo.get(Cinder.Download.Intent, intent.id)
        if is_nil(fresh), do: Repo.rollback(:stale_intent)

        attrs = %{
          download_id: fresh.remote_id,
          download_protocol: fresh.protocol,
          release_title: fresh.release["title"],
          mapping_snapshot: fresh.mapping_snapshot,
          release_policy_snapshot: fresh.release_policy_snapshot,
          mapping_status: :resolved
        }

        grab =
          %Grab{}
          |> Grab.reservation_changeset(attrs)
          |> Repo.insert()
          |> case do
            {:ok, grab} -> grab
            {:error, changeset} -> Repo.rollback(changeset)
          end

        {linked, _rows} =
          Repo.update_all(
            from(e in Episode,
              where:
                e.id in ^fresh.episode_ids and is_nil(e.grab_id) and is_nil(e.file_path) and
                  e.monitored == true
            ),
            set: [grab_id: grab.id, updated_at: now()]
          )

        if linked != length(fresh.episode_ids), do: Repo.rollback(:episode_ownership_changed)

        Repo.delete!(fresh)
        grab
      end)

    with {:ok, grab} <- result do
      broadcast_grab_series(grab)
      {:ok, grab}
    end
  end

  @doc "Persists an anime mapping preflight outcome (resolved, or held with its reason) and broadcasts."
  def record_mapping_result(%Grab{} = grab, {:ok, _preflight}) do
    persist_mapping_result(grab, %{mapping_status: :resolved, mapping_issue: nil})
  end

  def record_mapping_result(%Grab{} = grab, {:needs_mapping, %{issue: issue}}) do
    persist_mapping_result(grab, %{mapping_status: :needs_mapping, mapping_issue: issue})
  end

  defp persist_mapping_result(grab, attrs) do
    case grab |> Grab.mapping_changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        broadcast_grab_series(updated)
        {:ok, updated}

      {:error, _changeset} = error ->
        error
    end
  end

  @doc """
  Releases a mapping hold: the operator has fixed the files on disk (e.g. renamed them), so this
  flips the grab back to `:resolved` (resetting `download_attempts`, mirroring
  `retry_grab_verification/1`) and lets the TV poller's next import tick run a fresh preflight
  over the current files. A preflight that fails again simply re-holds with an updated reason —
  there is no separate retry budget for the hold itself, since re-entry only happens on this
  explicit operator action, never automatically.
  """
  defdelegate retry_grab_mapping(grab), to: ReleaseVerification

  defp broadcast_grab_series(grab) do
    # Post-commit side effect, best-effort: once the txn committed the grab is
    # real, and a blip here (a pool-checkout timeout on the series lookup) must
    # not surface as {:error, _} — the TvPoller's cleanup branch would then
    # remove the client download out from under a live grab and eventually
    # blocklist a good release.
    broadcast_series(series_id_for_grab(grab.id))
  rescue
    e -> Logger.warning("post-commit broadcast for grab #{grab.id} failed: #{inspect(e)}")
  catch
    kind, value ->
      Logger.warning("post-commit broadcast for grab #{grab.id} #{kind}: #{inspect(value)}")
  end

  defp insert_and_link_grab(download_id, protocol, episode_ids, release_title, opts) do
    case %Grab{}
         |> Grab.changeset(%{
           download_id: download_id,
           download_protocol: protocol,
           release_title: release_title
         })
         |> Repo.insert() do
      {:ok, grab} -> link_grab_episodes(grab, episode_ids, opts)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp link_grab_episodes(grab, episode_ids, opts) do
    # reset_attempts: the manual-grab path zeroes search_attempts (mirroring manual_grab_movie),
    # giving the user-chosen release a fresh budget — and keeping the counter from ever exceeding
    # the cap, which announce_search_exhausted's == max crossing check relies on.
    reset = if Keyword.get(opts, :reset_attempts, false), do: [search_attempts: 0], else: []
    # Guard `is_nil(grab_id)`: never re-link an episode another grab already owns (defends against
    # a same-tick double-link silently overwriting an earlier grab). Guard `monitored`: every
    # caller sources episode_ids from wanted_episodes (monitored-only), but the poller's search
    # pass holds that snapshot across seconds of indexer/client I/O — an admin cancel_series in
    # that window unmonitors the episodes, and linking them anyway would resurrect the download
    # the user just cancelled.
    {linked, _} =
      Repo.update_all(
        from(e in Episode,
          where: e.id in ^episode_ids and is_nil(e.grab_id) and e.monitored == true
        ),
        set: [grab_id: grab.id, updated_at: now()] ++ reset
      )

    # Every requested episode was already grabbed (or unmonitored meanwhile): roll back so we
    # don't leave an orphan grab (and so the caller doesn't start a download serving nothing).
    if linked == 0, do: Repo.rollback(:no_episodes_linked), else: grab
  end

  @doc """
  Marks a grab downloaded (records `content_path`, the at-rest path to import) and broadcasts.
  Also resets `download_attempts` at the download→import boundary (mirrors the movie poller's
  `import_attempts: 0` reset, `poller.ex:140`) so download-phase blips don't starve the shared
  grab-lifetime retry budget the import pass then draws from.
  """
  def mark_grab_downloaded(%Grab{} = grab, content_path) do
    changeset =
      Grab.changeset(grab, %{
        content_path: content_path,
        download_attempts: 0,
        download_progress: nil,
        download_speed: nil,
        download_eta: nil
      })

    with {:ok, grab} <- Repo.update(changeset) do
      broadcast_series(series_id_for_grab(grab.id))
      {:ok, grab}
    end
  end

  @doc """
  Bumps a grab's `download_attempts` — the single grab-lifetime retry counter the TV poller
  uses for both the advance and import passes — and broadcasts. The caller compares the
  pre-bump count against its bound to decide retry-vs-park.
  """
  def increment_grab_attempts(%Grab{} = grab) do
    Repo.update_all(from(g in Grab, where: g.id == ^grab.id),
      inc: [download_attempts: 1],
      set: [download_progress: nil, download_speed: nil, download_eta: nil, updated_at: now()]
    )

    broadcast_series(series_id_for_grab(grab.id))
    :ok
  end

  @doc "Atomically holds a downloaded resolved grab after its final verification attempt."
  defdelegate hold_grab_verification(grab), to: ReleaseVerification

  @doc "Atomically releases a verification hold and resets only its verification attempts."
  defdelegate retry_grab_verification(grab), to: ReleaseVerification

  @doc """
  Deletes a grab; the `grab_id` FK (`on_delete: :nilify_all`) unlinks its episodes. Broadcasts
  `{:series_updated, series_id}` (captured before the delete, while the links still exist).
  """
  def delete_grab(%Grab{} = grab) do
    series_id = series_id_for_grab(grab.id)

    # allow_stale: the TV poller may finish/park the same grab concurrently with a
    # user-initiated delete; an already-gone row is success for an idempotent delete.
    with {:ok, grab} <- Repo.delete(grab, allow_stale: true) do
      broadcast_series(series_id)
      {:ok, grab}
    end
  end

  @doc """
  Aborts one grab as a user action. Its delete and durable cleanup fence commit together; remote
  cleanup runs afterward and retries from the fence on failure. Its episodes then re-enter the
  wanted sweep and re-search cleanly.
  """
  def cancel_grab(%Grab{} = grab), do: cancel_grab(grab, :any_state)

  @doc """
  Aborts a grab only while it is still held for mapping. The held-state claim, cleanup fence, and
  delete share one transaction so a concurrent mapping resume cannot be cancelled afterward.
  """
  def cancel_mapping_grab(%Grab{} = grab), do: cancel_grab(grab, :needs_mapping)

  defp cancel_grab(grab, required_state) do
    result =
      Repo.transaction(fn ->
        case Repo.update_all(cancel_grab_query(grab.id, required_state),
               set: [updated_at: now()]
             ) do
          {0, _} when required_state == :needs_mapping ->
            Repo.rollback(:mapping_not_held)

          {0, _} ->
            {grab, [], nil}

          {1, _} ->
            episode_ids = episode_ids_for_grab(grab.id)
            series_id = series_id_for_grab(grab.id)

            intent_ids =
              Download.fence_episode_cleanup(episode_ids, [grab_cleanup_spec(grab, episode_ids)])

            {:ok, deleted} = Repo.delete(grab, allow_stale: true)
            {deleted, intent_ids, series_id}
        end
      end)

    with {:ok, {deleted, intent_ids, series_id}} <- result do
      Download.cleanup_intents(intent_ids)
      broadcast_series(series_id)
      {:ok, deleted}
    end
  end

  defp cancel_grab_query(id, :any_state), do: from(g in Grab, where: g.id == ^id)

  defp cancel_grab_query(id, :needs_mapping),
    do: from(g in Grab, where: g.id == ^id and g.mapping_status == :needs_mapping)

  @doc """
  Cancels an entire series WITHOUT deleting it: reaps every grab serving the series (any state,
  including `:downloaded` awaiting import — a surviving downloaded grab would re-import next tick),
  removing each tracked client download, then unmonitors every season and episode so the TV
  poller's `wanted_episodes` does not re-grab. Broadcasts `{:series_updated, id}`. Audited.

  Grab deletes, season+episode unmonitoring, the audit row, and durable cleanup fences are written
  in one transaction, so there is no poller-visible window where an episode is grab-less but still
  monitored. Client I/O runs only after commit; failures leave fences for reconciliation.
  """
  def cancel_series(%Series{} = series, actor) do
    result =
      Repo.transaction(fn ->
        episode_ids = episode_ids_for_series(series.id)
        unmonitor_series_tree(series.id)
        grabs = grabs_for_series(series.id)
        specs = Enum.map(grabs, &grab_cleanup_spec(&1, episode_ids_for_grab(&1.id)))

        # allow_stale: the TV poller may have finished/parked a grab between reads.
        for grab <- grabs, do: Repo.delete!(grab, allow_stale: true)
        intent_ids = Download.fence_episode_cleanup(episode_ids, specs)
        Audit.log_or_rollback(actor, :cancel_series, series, %{title: series.title})
        {series, intent_ids}
      end)

    with {:ok, {_, intent_ids}} <- result do
      Download.cleanup_intents(intent_ids)
      broadcast_series(series.id)
      {:ok, series}
    end
  end

  @doc """
  Deletes a series and its tree. Grab deletes and durable remote-cleanup fences commit in the same
  transaction as the series cascade, so the episode links cannot disappear before their remote IDs
  are recoverable. Client I/O runs after commit. Broadcasts
  `{:series_deleted, id}`. Audited. Pass `delete_files: true` to also unlink every episode
  `file_path` after the cascade (best-effort, non-blocking).
  """
  def delete_series(%Series{} = series, actor, opts \\ []) do
    delete_files? = Keyword.get(opts, :delete_files, false)
    # Collect episode file paths BEFORE the cascade deletes the rows.
    paths = if delete_files?, do: episode_file_paths_for_series(series.id), else: []
    prepare = &prepare_series_cleanup/1

    with {:ok, {deleted, intent_ids}} <-
           delete_with_audit(series, actor, :delete_series, delete_files?, prepare) do
      Download.cleanup_intents(intent_ids)
      Enum.each(paths, &best_effort_delete_file/1)
      broadcast_series_deleted(deleted.id)
      {:ok, deleted}
    end
  end

  defp episode_file_paths_for_series(series_id) do
    Repo.all(
      from e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: s.series_id == ^series_id and not is_nil(e.file_path),
        select: e.file_path
    )
  end

  defp episode_ids_for_series(series_id) do
    Repo.all(
      from e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: s.series_id == ^series_id,
        select: e.id
    )
  end

  @doc false
  def episode_ids_for_grab(grab_id) do
    Repo.all(from e in Episode, where: e.grab_id == ^grab_id, select: e.id)
  end

  defp prepare_series_cleanup(series) do
    episode_ids = episode_ids_for_series(series.id)
    grabs = grabs_for_series(series.id)
    specs = Enum.map(grabs, &grab_cleanup_spec(&1, episode_ids_for_grab(&1.id)))
    intent_ids = Download.fence_episode_cleanup(episode_ids, specs)
    Enum.each(grabs, &Repo.delete!(&1, allow_stale: true))
    intent_ids
  end

  @doc false
  def grab_cleanup_spec(grab, episode_ids) do
    %{
      remote_id: grab.download_id,
      protocol: grab.download_protocol,
      title: grab.release_title,
      episode_ids: episode_ids
    }
  end

  # Grabs whose episodes belong to this series (via the episode→season join), ALL states.
  defp grabs_for_series(series_id) do
    Repo.all(
      from g in Grab,
        join: e in Episode,
        on: e.grab_id == g.id,
        join: s in Season,
        on: s.id == e.season_id,
        where: s.series_id == ^series_id,
        distinct: true
    )
  end

  # Unmonitor every season + episode of the series in one write each so wanted_episodes is empty.
  defp unmonitor_series_tree(series_id) do
    ts = now()

    Repo.update_all(from(s in Series, where: s.id == ^series_id),
      set: [monitored: false, monitor_strategy: :none, updated_at: ts]
    )

    Repo.update_all(from(s in Season, where: s.series_id == ^series_id),
      set: [monitored: false, updated_at: ts]
    )

    Repo.update_all(
      from(e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: s.series_id == ^series_id
      ),
      set: [monitored: false, updated_at: ts]
    )

    :ok
  end

  @doc """
  Finalizes a grab after import, in **one transaction**: sets `file_path` (and clears `grab_id`)
  on each imported episode, bumps `search_attempts` on the grab's still-missing episodes, then
  deletes the grab. `imported` is `[{episode_id, dest_path}]`. Broadcasts `{:series_updated, _}`
  and announces any season the import completes.

  The search_attempts bump on the non-imported episodes makes a pack that never yields a wanted
  episode re-search with backoff and eventually search-park, rather than re-grabbing forever. It
  **must** run before the delete: the `grab_id` FK nilifies on delete, after which the predicate
  would match nothing. Each imported episode is written individually (a single `update_all set:`
  could not give each its own dest); `n` is one season pack, so the per-row writes are cheap. The
  `file_path` XOR `grab_id` invariant (derived state) is maintained here, the single write site.
  """
  def finish_grab(%Grab{} = grab, imported \\ []), do: finish_grab(grab, imported, [])

  def finish_grab(%Grab{} = grab, imported, stage_ids) do
    imported_ids = imported |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    series_id = series_id_for_grab(grab.id)

    result =
      Repo.transaction(fn ->
        ts = now()

        for {episode_id, dest, q} <- imported do
          update_imported_episode!(grab.id, episode_id, dest, q, ts)
        end

        # select: in the update_all (RETURNING) hands the bumped ids to the post-commit
        # exhaustion announce without a leading SELECT — a read-then-write transaction is
        # the SQLITE_BUSY class busy_timeout can't rescue (see config/test.exs), and the
        # delete below nilifies grab_id so the ids can't be re-derived afterwards.
        {_count, bumped_ids} =
          Repo.update_all(
            missing_episodes_query(grab.id, imported_ids) |> select([e], e.id),
            inc: [search_attempts: 1],
            set: [updated_at: ts]
          )

        completed_seasons = completed_seasons_for_imported_episodes(imported_ids)

        ImportStage.mark_committed!(stage_ids)
        Repo.delete!(grab)
        {bumped_ids, completed_seasons}
      end)

    with {:ok, {bumped_ids, completed_seasons}} <- result do
      broadcast_series(series_id)
      announce_search_exhausted(bumped_ids)
      Enum.each(completed_seasons, &Notifier.notify({:season_available, &1}))
      {:ok, grab}
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale_grab}
  end

  defp update_imported_episode!(grab_id, episode_id, dest, quality, timestamp) do
    query =
      from e in Episode,
        where: e.id == ^episode_id and e.grab_id == ^grab_id and e.monitored == true

    updates = [
      file_path: dest,
      grab_id: nil,
      imported_resolution: quality.resolution,
      imported_size: quality.size,
      imported_language: quality.language,
      imported_source: quality.source,
      imported_audio_languages: quality.audio_languages,
      imported_embedded_subtitles: quality.embedded_subtitles,
      imported_sidecar_subtitles: quality.sidecar_subtitles,
      updated_at: timestamp
    ]

    case Repo.update_all(query, set: updates) do
      {1, _} -> :ok
      {0, _} -> Repo.rollback(:stale_grab)
    end
  end

  # The grab's episodes that did not import. Branch on the empty case so we never interpolate
  # an empty list into `not in` (and so a park — empty `imported` — bumps every linked episode).
  defp missing_episodes_query(grab_id, []), do: from(e in Episode, where: e.grab_id == ^grab_id)

  defp missing_episodes_query(grab_id, imported_ids),
    do: from(e in Episode, where: e.grab_id == ^grab_id and e.id not in ^imported_ids)

  defp completed_seasons_for_imported_episodes([]), do: []

  defp completed_seasons_for_imported_episodes(imported_ids) do
    today = Date.utc_today()

    imported_season_ids =
      from e in Episode,
        where: e.id in ^imported_ids and not is_nil(e.air_date) and e.air_date <= ^today,
        select: e.season_id,
        distinct: true

    from([_episode, season, series] in available_seasons_query(today),
      where: season.id in subquery(imported_season_ids),
      select: %{
        title: series.title,
        season_number: season.season_number,
        poster_path: series.poster_path
      }
    )
    |> Repo.all()
  end

  @doc """
  Parks a grab: deletes it and bumps every linked episode's `search_attempts` (so they re-search,
  bounded, then search-park). The terminal-failure case of `finish_grab/2` (nothing imported).
  """
  def park_grab(%Grab{} = grab), do: finish_grab(grab, [])

  @doc """
  Atomically rejects one confirmed movie release: exact-title blocklist, durable remote cleanup,
  and guarded requeue. Upgrade rejection keeps the live library file and imported quality.
  """
  defdelegate reject_movie_release(expected, evidence), to: ReleaseVerification

  @doc """
  Atomically rejects one confirmed episodic release, guarding the resolved grab and its exact
  episode ownership before blocklisting, fencing cleanup, and deleting it.
  """
  defdelegate reject_grab_release(expected, evidence), to: ReleaseVerification

  @doc """
  Records `movie`'s current `release_title` as blocked for that movie, so release selection
  skips it on the next search. A nil `release_title` (e.g. a pre-grab park) is a no-op.

  **Non-raising**: runs inside the poller's isolated park path, where a raise would re-fire
  every tick (`isolate` never parks). So it uses a non-bang insert, logs and swallows any
  `{:error, _}`, and always returns `:ok` (mirrors `Download.best_effort_remove/2`). No broadcast.
  """
  def block_release(%Movie{release_title: nil}, _reason), do: :ok

  def block_release(%Movie{release_title: title, id: movie_id}, reason),
    do:
      insert_blocked_release(fn ->
        %{release_title: title, reason: to_string(reason), movie_id: movie_id}
      end)

  @doc """
  Records `grab`'s `release_title` as blocked for its series. Resolves the series from the grab's
  still-linked episodes, so call it **before** `park_grab/1` deletes the grab (the FK nilifies the
  links on delete). A nil `release_title` is a no-op. **Non-raising** — see `block_release/2`.
  """
  def block_grab_release(%Grab{release_title: nil}, _reason), do: :ok

  def block_grab_release(%Grab{release_title: title, id: grab_id}, reason),
    do:
      insert_blocked_release(fn ->
        # series_id_for_grab is a DB query: building attrs lazily keeps it INSIDE the catch below,
        # so the TV park path's series resolution can't raise/exit out and abort park_grab.
        %{release_title: title, reason: to_string(reason), series_id: series_id_for_grab(grab_id)}
      end)

  # Non-raising on every path (mirrors `Download.best_effort_remove/2`): the attrs thunk is run
  # inside the try, so a changeset/constraint `{:error, _}` is logged-and-swallowed AND a
  # raised/exited DB failure (in the insert OR the lazy series-id query) is caught — because the
  # TV caller blocks BEFORE `park_grab` deletes the grab, a raise here would stop the park and
  # hot-loop the grab every tick.
  defp insert_blocked_release(build_attrs) do
    attrs = build_attrs.()

    case %BlockedRelease{} |> BlockedRelease.changeset(attrs) |> Repo.insert() do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning("block_release failed for #{inspect(attrs)}: #{inspect(changeset.errors)}")
        :ok
    end
  catch
    kind, value ->
      Logger.warning("block_release raised: #{inspect({kind, value})}")
      :ok
  end

  @doc "Downcased-or-not release titles blocked for `movie` (the exact strings stored)."
  def blocked_release_titles(%Movie{id: movie_id}),
    do:
      Repo.all(from b in BlockedRelease, where: b.movie_id == ^movie_id, select: b.release_title)

  @doc "Release titles blocked for the series `series_id`."
  def blocked_release_titles_for_series(series_id),
    do:
      Repo.all(
        from b in BlockedRelease, where: b.series_id == ^series_id, select: b.release_title
      )

  @doc """
  Bumps `search_attempts` (and `updated_at`, for the poller's search backoff) on the given
  episodes in one write, then broadcasts each affected series. Used by the search pass on
  no-match / client-add failure / indexer error (no grab exists yet on that path).
  """
  # The TV sweep's per-episode search-attempt cap. Lives here (not in the poller) because the
  # UI derives :search_parked from it — the sweep's skip bound and the badge must agree.
  # (Defined before its first use below; read via max_search_attempts/0 further down.)
  def increment_search_attempts([]), do: :ok

  def increment_search_attempts(episode_ids) when is_list(episode_ids) do
    Repo.update_all(from(e in Episode, where: e.id in ^episode_ids),
      inc: [search_attempts: 1],
      set: [updated_at: now()]
    )

    for series_id <- series_ids_for_episodes(episode_ids), do: broadcast_series(series_id)
    announce_search_exhausted(episode_ids)
    :ok
  end

  # After any search_attempts bump: episodes that just crossed the cap leave the sweep
  # permanently, and that moment must never be silent (the movie analogue parks visibly at
  # :search_failed). Lives at the write site so BOTH bump paths announce — the sweep's
  # increment_search_attempts and finish_grab/park_grab's non-imported bump. Re-selecting
  # fresh rows also makes the check immune to stale in-memory counters. Monitored-only: a
  # parked grab of a just-cancelled series bumps unmonitored episodes the sweep doesn't own.
  # Single-series by construction (both callers pass one grab/season group); the notifier
  # payload's episodes carry season: :series for the transports' summary line.
  defp announce_search_exhausted([]), do: :ok

  # Best-effort like create_grab's post-commit broadcast (and guarded the same way): it runs
  # AFTER the bump/finalize committed, so a re-select raise here (pool-checkout timeout,
  # SQLITE_BUSY) must not escape — in finish_grab's caller that would skip the client-download
  # removal and the availability notification for a grab row that is already gone.
  #
  # >= rather than ==: crossings normally land exactly at the cap (new grabs reset or start
  # below it), but pre-existing data can sit at the cap inside an in-flight grab and get
  # bumped past it. A capped episode can't re-announce — the sweep skips it and every grab
  # path resets — so >= adds no duplicates, only catches the above-cap stragglers.
  defp announce_search_exhausted(episode_ids) do
    exhausted =
      Repo.all(
        from e in Episode,
          where:
            e.id in ^episode_ids and e.search_attempts >= ^@max_search_attempts and
              is_nil(e.file_path) and is_nil(e.grab_id) and e.monitored == true,
          preload: [season: :series]
      )

    case exhausted do
      [] ->
        :ok

      [%{season: %{series: series, season_number: season}} | _] = episodes ->
        numbers = Enum.map(episodes, & &1.episode_number)

        Logger.warning(
          "tv search exhausted for #{series.title} season #{season} episode(s) " <>
            "#{inspect(numbers)}; the sweep will skip them until a manual Search"
        )

        Notifier.notify({:episodes_search_exhausted, episodes})
    end
  rescue
    e -> Logger.warning("search-exhaustion announce failed: #{inspect(e)}")
  catch
    kind, value -> Logger.warning("search-exhaustion announce #{kind}: #{inspect(value)}")
  end

  defp series_ids_for_episodes(episode_ids) do
    Repo.all(
      from e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: e.id in ^episode_ids,
        select: s.series_id,
        distinct: true
    )
  end

  @doc "Grabs still downloading (no `content_path` yet)."
  def list_grabs_downloading, do: Repo.all(from g in Grab, where: is_nil(g.content_path))

  @doc "Count of grabs still downloading (no `content_path` yet)."
  def count_grabs_downloading,
    do: Repo.aggregate(from(g in Grab, where: is_nil(g.content_path)), :count)

  @doc """
  Grabs downloaded and awaiting import (`content_path` set), with `episodes: [season: :series]`
  preloaded so the TV poller's import pass can map files → episodes and build library paths
  without reaching past the Catalog boundary.
  """
  def list_grabs_downloaded do
    Repo.all(
      from g in Grab,
        where: not is_nil(g.content_path) and g.mapping_status == :resolved,
        preload: [episodes: [season: :series]]
    )
  end

  @doc "All grabs newest-first, with `episodes: [season: :series]` preloaded for the admin /grabs view."
  def list_grabs do
    Repo.all(from g in Grab, order_by: [desc: g.id], preload: [episodes: [season: :series]])
  end

  @doc "Lists held mapping grabs for one series, oldest first, with their series tree preloaded."
  def list_mapping_grabs_for_series(series_id) do
    Repo.all(
      from g in Grab,
        join: episode in assoc(g, :episodes),
        join: season in assoc(episode, :season),
        where: season.series_id == ^series_id and g.mapping_status == :needs_mapping,
        distinct: true,
        order_by: [asc: g.id],
        preload: [episodes: [season: :series]]
    )
  end

  @doc """
  Fetches one grab by id, or `nil`. User-initiated grab actions (e.g. /activity's
  delete) must re-read before acting: a grab resolved from a rendered snapshot may
  have finished importing meanwhile, and cancelling THAT would remove a completed,
  already-imported torrent from the client (stopping seeding) for nothing.
  """
  def get_grab(id), do: Repo.get(Grab, id)

  @doc """
  The SQL-expressible wanted set: monitored episodes with no file and no active grab whose
  `air_date` has passed (set and `<= today`). Preloads `season: :series` for the poller's
  search + season-grouping. Backoff/bound filtering (search_attempts, retry window) is applied
  by the TV poller, matching the movie poller's split. Gated on the leaf `episode.monitored`
  flag (the cascade/add keep it the single source of truth).

  Regular episodes keep the existing positive season/episode-number gate. Explicitly monitored,
  classified Anime story specials and recaps share the common missing/air-date predicates; extras
  and Standard Season 00 rows remain excluded.
  """
  def wanted_episodes do
    Repo.all(from e in wanted_episodes_query(), preload: [season: :series])
  end

  @doc "Count of wanted episodes (see `wanted_episodes/0`)."
  def count_wanted_episodes, do: Repo.aggregate(wanted_episodes_query(), :count)

  @doc """
  `{series tmdb_id, season_number}` pairs whose content has fully landed: at least one
  episode file, and no aired episode still missing one — monitored or not, because a
  `:future`-strategy season with only its newest episode imported must NOT read Available
  (that would hide the Request affordance for a season that's 90% absent). Drives the
  requester-facing season badges — availability outranks a stale request status
  (mirroring the movie `title_state` precedence), otherwise a fully imported season
  reads "Approved"/"Denied" forever. Pass `tmdb_id` to scope to one series.
  """
  def available_season_keys(tmdb_id \\ nil) do
    today = Date.utc_today()

    query = available_seasons_query(today)

    query = if tmdb_id, do: where(query, [_e, _s, sr], sr.tmdb_id == ^tmdb_id), else: query

    query
    |> select([_e, s, sr], {sr.tmdb_id, s.season_number})
    |> Repo.all()
    |> MapSet.new()
  end

  defp available_seasons_query(today) do
    from e in Episode,
      join: s in assoc(e, :season),
      join: sr in assoc(s, :series),
      where: s.season_number > 0,
      group_by: [s.id, s.season_number, sr.id, sr.tmdb_id, sr.title, sr.poster_path],
      having:
        filter(count(e.id), not is_nil(e.file_path)) > 0 and
          filter(
            count(e.id),
            is_nil(e.file_path) and not is_nil(e.air_date) and e.air_date <= ^today
          ) == 0
  end

  @doc "Count of still-wanted episodes in one season of `series_id` (see `wanted_episodes/0`)."
  def count_wanted_episodes(series_id, season_number) do
    Repo.aggregate(
      from([e, s] in wanted_episodes_query(),
        where: s.series_id == ^series_id and s.season_number == ^season_number
      ),
      :count
    )
  end

  @doc "Count of all episodes in one season of `series_id`."
  def count_episodes(series_id, season_number) do
    Repo.aggregate(
      from(e in Episode,
        join: s in assoc(e, :season),
        where: s.series_id == ^series_id and s.season_number == ^season_number
      ),
      :count
    )
  end

  @doc "See `episode_state/2`: past this many search attempts the sweep skips the episode."
  def max_search_attempts, do: @max_search_attempts

  @doc """
  Derived pipeline state for an episode (episodes carry no status enum): a file ⇒ `:available`,
  an active grab ⇒ `:downloading`, unaired/undated ⇒ `:upcoming`, sweep gave up
  (`search_attempts >= max_search_attempts/0`) ⇒ `:search_parked` (a manual Search re-queues
  it via `search_episode_now/1`), else `:wanted`.
  """
  def episode_state(%Episode{} = episode, today \\ Date.utc_today()) do
    cond do
      episode.file_path -> :available
      episode.grab_id -> :downloading
      is_nil(episode.air_date) or Date.compare(episode.air_date, today) == :gt -> :upcoming
      episode.search_attempts >= @max_search_attempts -> :search_parked
      true -> :wanted
    end
  end

  @doc """
  Re-queues a single searchable `episode` for the TV sweep by zeroing its `search_attempts`
  (clearing any backoff/attempt-cap park). The episode is re-read with its series profile before
  writing so a stale LiveView click cannot requeue an episode that is no longer eligible. Already
  imported or grabbed episodes preserve the existing no-op contract.
  """
  def search_episode_now(%Episode{id: id}) do
    case Repo.one(from e in Episode, where: e.id == ^id, preload: [season: :series]) do
      %Episode{} = episode ->
        cond do
          not is_nil(episode.file_path) or not is_nil(episode.grab_id) ->
            :ok

          episode_searchable?(episode, media_profile_summary(episode.season.series)) ->
            transition_episode(episode, %{search_attempts: 0})

          true ->
            {:error, :not_searchable}
        end

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Re-queues every still-wanted episode of one `season` (zeroes their `search_attempts`)."
  def search_season_now(%Season{id: season_id}) do
    wanted_episodes()
    |> Enum.filter(&(&1.season_id == season_id))
    |> Enum.each(&transition_episode(&1, %{search_attempts: 0}))
  end

  defp wanted_episodes_query do
    today = Date.utc_today()

    from e in Episode,
      join: s in assoc(e, :season),
      join: series in assoc(s, :series),
      where:
        e.monitored == true and is_nil(e.file_path) and is_nil(e.grab_id) and
          not is_nil(e.air_date) and e.air_date <= ^today,
      where:
        (s.season_number > 0 and e.episode_number > 0) or
          (series.media_profile == :anime and e.classification in [:story_special, :recap])
  end

  @doc "Whether one preloaded episode shares the wanted query's current eligibility semantics."
  def episode_searchable?(
        %Episode{season: %Season{} = season} = episode,
        profile,
        today \\ Date.utc_today()
      ) do
    common? =
      episode.monitored and is_nil(episode.file_path) and is_nil(episode.grab_id) and
        not is_nil(episode.air_date) and Date.compare(episode.air_date, today) != :gt

    regular? = season.season_number > 0 and episode.episode_number > 0
    special? = profile.effective == :anime and episode.classification in [:story_special, :recap]

    common? and (regular? or special?)
  end

  @doc """
  Monitored, dated episodes in a calendar window (`today - 7 .. today + 90`), ordered by air date,
  with `season: :series` preloaded for the calendar view. Excludes season 0 (specials, never
  searched in M5) so the view's derived "wanted" badge stays honest.
  """
  def upcoming_episodes do
    today = Date.utc_today()
    from_date = Date.add(today, -7)
    to_date = Date.add(today, 90)

    Repo.all(
      from e in Episode,
        join: s in assoc(e, :season),
        where:
          s.season_number > 0 and e.monitored and not is_nil(e.air_date) and
            e.air_date >= ^from_date and e.air_date <= ^to_date,
        order_by: [asc: e.air_date],
        preload: [season: :series]
    )
  end

  @doc """
  Re-fetches `series` from TMDB and reconciles its season/episode tree in one transaction, then
  broadcasts `{:series_updated, series.id}` once. Existing episodes are matched by
  `tmdb_episode_id` (series-wide, so a renumber that moves an episode across seasons is handled)
  and updated in place — preserving `monitored`, `file_path`, `grab_id`, and the attempt counters.
  Genuinely new regular episodes are inserted with `monitored` per the season flag; classified
  specials start unmonitored. New seasons are inserted; rows that vanished from TMDB are left
  untouched.

  Returns `{:ok, series}`, or `{:error, reason}` if a TMDB fetch fails (short-circuits before any
  write, mirroring `create_series/2`).
  """
  def refresh_series(%Series{} = series) do
    with {:ok, info} <- tmdb().get_series(series.tmdb_id),
         {:ok, seasons} <- fetch_seasons(series.tmdb_id, info.seasons),
         {:ok, identity} <-
           fetch_series_identity(series.tmdb_id, series.scene_numbering_group_id) do
      Repo.transaction(fn -> refresh_current_series(series.id, info, seasons, identity) end)
      |> finish_series_refresh(series.id)
    end
  end

  defp finish_series_refresh({:ok, updated}, series_id) do
    broadcast_series(series_id)
    {:ok, updated}
  end

  defp finish_series_refresh({:error, reason}, _series_id), do: {:error, reason}

  defp refresh_current_series(series_id, info, seasons, identity) do
    case Repo.get(Series, series_id) do
      %Series{} = current ->
        updated = update_series_row(current, info)
        reconcile_tree(updated, seasons)

        case sync_series_identity(updated, seasons, identity) do
          :ok -> updated
          {:error, reason} -> Repo.rollback(reason)
        end

      nil ->
        Repo.rollback(:stale_series)
    end
  end

  # Backfill the series row's TMDB-sourced fields (tvdb_id especially — the acquisition
  # disambiguation key, often nil at add time). Identity + user-controlled fields (tmdb_id,
  # monitored, monitor_strategy) are not cast, so they're preserved. On failure, log and keep the
  # existing row: a descriptive backfill failing must not abort the whole tree reconcile.
  defp update_series_row(series, info) do
    changeset =
      Series.refresh_changeset(series, %{
        tvdb_id: info.tvdb_id,
        title: info.title,
        year: info.year,
        poster_path: info.poster_path,
        original_language: info.original_language,
        # Descriptive backfill — Map.get (not dot) so a partial info map can't KeyError and abort
        # the whole tree reconcile. The real normalize_series always includes these.
        overview: Map.get(info, :overview),
        genres: Map.get(info, :genres),
        vote_average: Map.get(info, :vote_average),
        first_air_date: Map.get(info, :first_air_date)
      })

    case Repo.update(changeset) do
      {:ok, updated} ->
        updated

      {:error, cs} ->
        Logger.warning("refresh: series #{series.id} row update failed: #{inspect(cs.errors)}")
        series
    end
  end

  # Two-pass renumber. Building season targets first lets `ensure_season` insert any new seasons;
  # then we partition into matched (an existing row by tmdb_episode_id) vs new. PASS 1 parks every
  # matched row in a guaranteed-free slot, PASS 2 moves each to its final slot (now collision-free),
  # PASS 3 inserts the new rows. This handles within-season swaps and mid-season insertion shifts,
  # which the old one-at-a-time update couldn't (every move collided on the unique index).
  defp reconcile_tree(series, fetched_seasons) do
    existing_seasons = Map.new(seasons_for(series.id), &{&1.season_number, &1})
    by_tmdb = Map.new(episodes_for(series.id), &{&1.tmdb_episode_id, &1})

    # Step 1 — collect {fetched_episode, season} for each fetched season whose target season
    # exists (or was just inserted); skip a season ensure_season couldn't create. The full season
    # struct is carried so PASS 3 can use season.monitored as the source of truth for new
    # episodes (rather than the series-wide monitor_strategy, which is :none for per-season
    # requests even when a specific season is monitored).
    targets =
      Enum.flat_map(fetched_seasons, fn fs ->
        case ensure_season(series, existing_seasons, fs.season_number) do
          %Season{} = season -> Enum.map(fs.episodes, &{&1, season})
          nil -> []
        end
      end)

    # Step 2 — partition into matched (existing row found by tmdb_episode_id) vs new. Guard a nil
    # tmdb_episode_id (TMDB always sets it, but a nil never matches and must be treated as new).
    {matched, new} =
      Enum.split_with(targets, fn {fe, _season} ->
        not is_nil(fe.tmdb_episode_id) and Map.has_key?(by_tmdb, fe.tmdb_episode_id)
      end)

    matched =
      Enum.map(matched, fn {fe, season} ->
        {Map.fetch!(by_tmdb, fe.tmdb_episode_id), fe, season.id}
      end)

    # Never renumber an episode with an in-flight grab: its release's files are matched + named by
    # the episode's CURRENT SxxEyy at import, so moving it mid-download would mislabel them (or
    # leave them unmatched). Leave it untouched (like a vanished row); the next refresh after the
    # grab finishes reconciles it.
    matched = Enum.filter(matched, fn {existing, _fe, _season_id} -> is_nil(existing.grab_id) end)

    # PASS 1 — park each matched row's real slot with a unique non-colliding sentinel (-id) in its
    # current season (no season_id change here), so PASS 2 never collides matched-vs-matched. Carry
    # the parked struct forward: PASS 2's `cast` diffs against the struct's number, and a row whose
    # final number equals its *original* would otherwise be seen as unchanged and the SET would omit
    # episode_number, leaving it stuck at the sentinel. Diffing against the (negative) parked number
    # always fires.
    parked =
      Enum.map(matched, fn {existing, fe, season_id} ->
        {park_episode(existing), existing, fe, season_id}
      end)

    # PASS 2 — finalize each matched row to its final (season_id, episode_number). All matched slots
    # are now free, so matched-vs-matched never collides. The only residual is a target slot still
    # held by a *vanished* row (left untouched); finalize_or_restore then puts the row back at its
    # original positive slot rather than stranding it at the -id park sentinel.
    Enum.each(parked, fn {parked_ep, original, fe, season_id} ->
      finalize_or_restore(parked_ep, original, season_id, fe)
    end)

    # PASS 3 — insert new rows, after finalize so slots reflect final state. Use the season's
    # `monitored` flag as the source of truth: a per-season request sets monitor_strategy: :none
    # on the series but flips the requested season's monitored flag to true, so season.monitored
    # correctly reflects "do we want this season" while series.monitor_strategy does not.
    Enum.each(new, fn {fe, season} -> insert_episode(season, fe) end)
  end

  # Vacate a matched row's real slot before the finalize pass: -id never collides with a positive
  # TMDB number and is unique across the table (ids are unique). Returns the updated struct (number
  # = -id) for PASS 2 to diff against; on the should-never-happen failure, log and return the
  # original struct so the finalize pass still runs.
  defp park_episode(existing) do
    # Route through refresh_changeset (not raw change/2) so the (season_id, episode_number) unique
    # constraint is registered: a park can't realistically collide (-id is negative + unique), but
    # if it ever did it degrades to {:error} rather than raising and aborting the whole series.
    case existing
         |> Episode.refresh_changeset(%{episode_number: -existing.id})
         |> Repo.update() do
      {:ok, parked} ->
        parked

      {:error, changeset} ->
        log_reconcile_error({:error, changeset}, "park episode #{existing.id}")
        existing
    end
  end

  defp seasons_for(series_id), do: Repo.all(from s in Season, where: s.series_id == ^series_id)

  defp episodes_for(series_id) do
    Repo.all(
      from e in Episode,
        join: s in assoc(e, :season),
        where: s.series_id == ^series_id and not is_nil(e.tmdb_episode_id)
    )
  end

  defp ensure_season(_series, existing, number) when is_map_key(existing, number),
    do: Map.fetch!(existing, number)

  defp ensure_season(series, _existing, number) do
    attrs = %{
      series_id: series.id,
      season_number: number,
      monitored: series.monitor_strategy != :none
    }

    case %Season{} |> Season.refresh_changeset(attrs) |> Repo.insert() do
      {:ok, season} ->
        season

      {:error, changeset} ->
        Logger.warning(
          "refresh skipped new season #{number} of series #{series.id}: #{inspect(changeset.errors)}"
        )

        nil
    end
  end

  # Finalize a parked row to its target slot (monitored/file_path/grab_id/counters omitted from the
  # cast → preserved). If the target slot is held by a row that vanished from TMDB — the one residual
  # the two-pass can't resolve without touching vanished rows — restore the row to its original
  # positive slot rather than leaving it at the -id park sentinel, which would otherwise leak a
  # negative episode_number into wanted_episodes → the TV poller's search/import.
  defp finalize_or_restore(parked_ep, original, season_id, fe) do
    changeset =
      Episode.refresh_changeset(parked_ep, %{
        season_id: season_id,
        episode_number: fe.episode_number,
        title: fe.title,
        air_date: fe.air_date
      })

    case Repo.update(changeset) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        Logger.warning(
          "refresh: episode #{original.id} target slot occupied by a vanished row; " <>
            "restoring to its original number #{original.episode_number} instead"
        )

        parked_ep
        |> Episode.refresh_changeset(%{
          season_id: original.season_id,
          episode_number: original.episode_number
        })
        |> Repo.update()
        |> log_reconcile_error("restore episode #{original.id}")
    end
  end

  defp insert_episode(%Season{} = season, fe) do
    {classification, label} = Identity.classify_tmdb_episode(season.season_number, fe.title)

    %Episode{}
    |> Episode.refresh_changeset(%{
      season_id: season.id,
      tmdb_episode_id: fe.tmdb_episode_id,
      episode_number: fe.episode_number,
      title: fe.title,
      air_date: fe.air_date,
      classification: classification,
      classification_source: "tmdb",
      classification_label: label,
      monitored: season.monitored and classification == :regular
    })
    |> Repo.insert()
    |> log_reconcile_error("insert episode tmdb_ep #{fe.tmdb_episode_id}")
  end

  defp log_reconcile_error({:ok, _} = ok, _context), do: ok

  defp log_reconcile_error({:error, changeset}, context) do
    # Residual reconcile conflict (e.g. a new/restored row whose target slot is still held by a row
    # that vanished from TMDB and is left untouched by design) — rare; log and continue so the rest
    # of the tree still reconciles rather than aborting the whole series.
    Logger.warning("refresh skipped #{context}: #{inspect(changeset.errors)}")
    :ok
  end

  @doc false
  def series_id_for_grab(grab_id) do
    Repo.one(
      from e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: e.grab_id == ^grab_id,
        select: s.series_id,
        limit: 1
    )
  end

  defp series_id_for_season(season_id),
    do: Repo.one(from s in Season, where: s.id == ^season_id, select: s.series_id)

  # Convention: a movie event carries the full struct (a flat row a LiveView patches in place —
  # see broadcast/1's {:movie_updated, movie}); a series event carries only the id, because a
  # series is a tree the detail view re-derives on receipt. A new media type picks the shape that
  # matches it (flat row → struct, tree → id).
  #
  # A nil series_id (e.g. a grab whose episodes were all unlinked) is a no-op, so callers
  # don't each need to guard it.
  @doc false
  def broadcast_series(nil), do: :ok

  def broadcast_series(series_id),
    do: Phoenix.PubSub.broadcast(Cinder.PubSub, @series_topic, {:series_updated, series_id})

  @doc "Broadcasts `{:series_deleted, id}` on the `\"series\"` topic so open views drop the row."
  def broadcast_series_deleted(id),
    do: Phoenix.PubSub.broadcast(Cinder.PubSub, @series_topic, {:series_deleted, id})
end
