defmodule Cinder.Catalog.SeriesCatalog do
  @moduledoc """
  Series/season/episode CRUD: TMDB-backed creation (`add_series/2`, find-or-create
  for a requested season), monitoring toggles, the derived wanted/upcoming-episode
  queries the TV poller and calendar read, and the identity-sync machinery (TMDB
  aliases + absolute/scene episode-group coordinates) shared by creation and
  refresh. Carved out of `Cinder.Catalog` as plain code motion — broadcasting
  still goes through `Cinder.Catalog.broadcast_series/1` (the single "series"
  topic choke-point); every public function here is re-exported unchanged via
  `defdelegate` in `Cinder.Catalog`.
  """
  import Ecto.Query
  require Logger

  alias Cinder.Catalog.{Episode, Identity, SceneNumbering, Season, Series}
  alias Cinder.Locales
  alias Cinder.Repo

  @max_search_attempts 10

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

  # Duplicated from Cinder.Catalog's own copy (used there by
  # anime_movie_acquisition_context/1) — tiny enough to keep as two independent copies rather
  # than share a module for it.
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

  @doc "Series currently held at search time on unsatisfiable Anime preferences (see `Cinder.Catalog.set_anime_hold/2`); surfaced on `/activity`."
  def list_anime_held_series do
    Repo.all(from s in Series, where: not is_nil(s.anime_hold_reason), order_by: s.title)
  end

  @doc """
  Refreshes a series' descriptive TMDB metadata (overview/genres/rating/first air date) with a
  lightweight `get_series` fetch, not the full `Cinder.Catalog.SeriesRefresh.refresh_series/1`
  season walk. Returns the refreshed `%Series{}` (or the row unchanged, logged, on a TMDB error).
  No broadcast — the caller reloads its own tree.
  """
  def enrich_series(%Series{} = series),
    do:
      Cinder.Catalog.backfill_metadata(
        series,
        &tmdb().get_series(&1.tmdb_id),
        &Series.metadata_changeset/2,
        "series"
      )

  @doc "Episodes with an imported file, season+series+scene-coordinates preloaded (subtitle-fetch candidates)."
  def list_episodes_with_file do
    Repo.all(
      from e in Episode,
        where: not is_nil(e.file_path),
        preload: [:episode_coordinates, season: :series]
    )
  end

  @doc """
  Sets a series' preferred language and zeroes `search_attempts` on its still-wanted
  episodes (no file, no grab) so a previously language-stranded season re-enters the
  search sweep. Available / in-flight episodes are untouched.
  """
  def set_series_language(%Series{} = series, language) do
    result =
      Repo.transaction(fn ->
        case write_series_language(series, language) do
          {:ok, updated} -> updated
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, updated} <- result do
      Cinder.Catalog.broadcast_series(series.id)
      {:ok, updated}
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  defp write_series_language(series, language) do
    with {:ok, updated} <-
           series
           |> Series.language_changeset(%{preferred_language: language})
           |> Repo.update() do
      from(e in Episode,
        join: s in Season,
        on: e.season_id == s.id,
        where:
          s.series_id == ^series.id and is_nil(e.file_path) and is_nil(e.grab_id) and
            e.search_attempts > 0
      )
      |> Repo.update_all(set: [search_attempts: 0])

      {:ok, updated}
    end
  end

  @doc "Fetches a series by TMDB id, or `nil`."
  def get_series_by_tmdb_id(tmdb_id), do: Repo.get_by(Series, tmdb_id: tmdb_id)

  @doc "Lists series, newest first."
  def list_series, do: Repo.all(from s in Series, order_by: [desc: s.id])

  @doc "Number of series in the catalog."
  def count_series, do: Repo.aggregate(Series, :count)

  @doc """
  Bytes on disk per series (`%{series_id => bytes}`), for the `/library` size sort and readout.
  Series with nothing imported are absent from the map, not zero.

  Deduplicates by the complete primary-plus-parts path bundle. `Cinder.Library.link_all/4` gives
  one multi-episode source **one** destination that every covered episode references, and
  `update_imported_episode!/5` writes the full imported size to each of those rows — so a bare
  `sum(imported_size)` double-counts a double-episode file. A part-only bundle left by a partial
  unlink still counts until its final path is removed.

  Two known inexactnesses, recorded rather than fixed:

    * `Cinder.Library.stage_anime_all/5` groups by `{source, season_number}` rather than by source
      alone, so one physical file spanning two seasons gets two destinations and is counted twice.
    * Episode rows written before the `imported_size` column existed carry a `file_path` with no
      size and are excluded, so an old series can read smaller than a new one. The predicate stays
      — without it the group-by emits NULL groups.
  """
  def series_library_sizes do
    per_file =
      from e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where:
          not is_nil(e.imported_size) and
            (not is_nil(e.file_path) or fragment("json_array_length(?) > 0", e.part_file_paths)),
        group_by: [s.series_id, e.file_path, e.part_file_paths],
        select: %{series_id: s.series_id, bytes: max(e.imported_size)}

    from(f in subquery(per_file), group_by: f.series_id, select: {f.series_id, sum(f.bytes)})
    |> Repo.all()
    |> Map.new()
  end

  ## TV series (M4a) — admin-only direct add; movie loop untouched.
  #
  # No PubSub topic yet: nothing subscribes until the M4b series-detail LiveView.
  # The whole tree inserts in one Repo.insert (= one transaction = one writer, so
  # WAL + busy_timeout stays correct).

  @doc """
  Adds a TV series and its season/episode tree, fetched from TMDB, flagging episodes
  `monitored` per `monitor_strategy` (`:all` / `:future` / `:none`; default `:future`).

  Find-or-create by `tmdb_id`: an already-added series is returned as-is; re-sync is
  `Cinder.Catalog.SeriesRefresh.refresh_series/1` (the periodic Refresher). Returns
  `{:ok, series}` (associations unloaded — preload `[seasons: :episodes]` to read the tree),
  `{:error, :invalid_monitor_strategy}` for an unknown strategy, or `{:error, reason}` if a
  TMDB fetch fails.
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

  Fetches all provider data before opening its transaction, then broadcasts once after commit.
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
    with {:ok, prepared} <- prepare_requested_series(tmdb_id, preferred, media_profile),
         {:ok, updated} <-
           persist_requested_series_in_transaction(
             prepared,
             season_number,
             preferred,
             media_profile
           ) do
      Cinder.Catalog.broadcast_series(updated.id)
      {:ok, updated}
    end
  end

  def find_or_create_series_at_requested(_tmdb_id, _season_number, _preferred, _media_profile),
    do: {:error, :invalid_media_profile}

  @doc "Fetches every TMDB payload needed to persist a requested series, without writing."
  def prepare_requested_series(tmdb_id, preferred, media_profile)
      when media_profile in [:auto, :standard, :anime] do
    case get_series_by_tmdb_id(tmdb_id) do
      %Series{} -> {:ok, {:existing, tmdb_id}}
      nil -> prepare_series(tmdb_id, :none, preferred, media_profile)
    end
  end

  def prepare_requested_series(_tmdb_id, _preferred, _media_profile),
    do: {:error, :invalid_media_profile}

  # DB-only half of request approval: the caller owns the transaction and post-commit broadcast.
  @doc false
  def persist_requested_series(prepared, season_number, preferred, media_profile)
      when media_profile in [:auto, :standard, :anime] do
    with {:ok, series} <- ensure_prepared_series(prepared),
         {:ok, series} <- apply_requested_media(series, media_profile, preferred),
         %Season{} = season <- season_in(series, season_number),
         {:ok, _season} <- write_season_monitored(season, true),
         {:ok, updated} <- mark_series_monitored(series) do
      {:ok, updated}
    else
      nil -> {:error, :season_not_found}
      {:error, _} = error -> error
    end
  end

  def persist_requested_series(_prepared, _season_number, _preferred, _media_profile),
    do: {:error, :invalid_media_profile}

  defp persist_requested_series_in_transaction(prepared, season_number, preferred, media_profile) do
    Repo.transaction(fn ->
      case persist_requested_series(prepared, season_number, preferred, media_profile) do
        {:ok, series} -> series
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp ensure_prepared_series({:existing, tmdb_id}) do
    case get_series_by_tmdb_id(tmdb_id) do
      %Series{} = series -> {:ok, series}
      nil -> {:error, :stale_series}
    end
  end

  defp ensure_prepared_series({:new, tmdb_id, attrs, seasons, identity}) do
    case get_series_by_tmdb_id(tmdb_id) do
      %Series{} = series ->
        {:ok, series}

      nil ->
        with {:ok, series} <- write_new_series(attrs, seasons, identity) do
          {:ok, get_series_by_tmdb_id(tmdb_id) || series}
        end
    end
  end

  defp apply_requested_media(series, media_profile, preferred) do
    pre_request_profile = series.media_profile

    with {:ok, series} <- fill_requested_language(series, preferred, pre_request_profile) do
      confirm_requested_profile(series, media_profile)
    end
  end

  defp fill_requested_language(
         %Series{preferred_language: "original"} = series,
         preferred,
         pre_request_profile
       )
       when preferred not in [nil, "original"] and pre_request_profile != :anime,
       do: write_series_language(series, preferred)

  defp fill_requested_language(series, _preferred, _pre_request_profile), do: {:ok, series}

  defp confirm_requested_profile(%Series{media_profile: :auto} = series, profile)
       when profile in [:standard, :anime],
       do: series |> Series.profile_changeset(%{media_profile: profile}) |> Repo.update()

  defp confirm_requested_profile(series, _profile), do: {:ok, series}

  defp season_in(series, season_number) do
    Repo.get_by(Season, series_id: series.id, season_number: season_number)
  end

  defp mark_series_monitored(series) do
    series |> Ecto.Changeset.change(monitored: true) |> Repo.update()
  end

  defp create_series(tmdb_id, strategy, preferred, media_profile) do
    with {:ok, {:new, ^tmdb_id, attrs, seasons, identity}} <-
           prepare_series(tmdb_id, strategy, preferred, media_profile) do
      insert_series(tmdb_id, attrs, seasons, identity)
    end
  end

  defp prepare_series(tmdb_id, strategy, preferred, media_profile) do
    with {:ok, info} <- tmdb().get_series(tmdb_id),
         {:ok, seasons} <- fetch_seasons(tmdb_id, info.seasons),
         seasons = put_episode_localizations(tmdb_id, seasons),
         # A brand-new series has no scene_numbering_group_id yet (create_changeset doesn't
         # cast it), so there's nothing to pre-fetch here.
         {:ok, identity} <- fetch_series_identity(tmdb_id, nil) do
      {:ok,
       {:new, tmdb_id, series_attrs(info, seasons, strategy, preferred, media_profile), seasons,
        identity}}
    end
  end

  defp insert_series(tmdb_id, attrs, seasons, identity) do
    result =
      Repo.transaction(fn ->
        case write_new_series(attrs, seasons, identity) do
          {:ok, series} -> series
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

  defp write_new_series(attrs, seasons, identity) do
    with {:ok, series} <- attrs |> Series.create_changeset() |> Repo.insert(),
         :ok <- sync_series_identity(series, seasons, identity) do
      {:ok, series}
    end
  end

  # Fetch each season's episodes, short-circuiting on the first TMDB error so a
  # partial tree is never persisted. Public (not private) — also called from
  # `Cinder.Catalog.SeriesRefresh.refresh_series/1`.
  @doc false
  def fetch_seasons(tmdb_id, season_stubs, locale \\ Locales.canonical()) do
    result =
      Enum.reduce_while(season_stubs, {:ok, []}, fn %{season_number: n}, {:ok, acc} ->
        case tmdb().get_season(tmdb_id, n, locale) do
          {:ok, season} -> {:cont, {:ok, [season | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    with {:ok, seasons} <- result, do: {:ok, Enum.reverse(seasons)}
  end

  @doc false
  def put_episode_localizations(tmdb_id, seasons) do
    titles =
      Enum.reduce(Locales.noncanonical(), %{}, fn locale, acc ->
        case fetch_seasons(tmdb_id, seasons, locale) do
          {:ok, localized} ->
            Map.put(acc, locale, episode_titles(localized))

          {:error, reason} ->
            Logger.warning(
              "episode localizations: series #{tmdb_id} locale #{locale} failed: " <>
                inspect(reason)
            )

            acc
        end
      end)

    Enum.map(seasons, &put_season_localizations(&1, titles))
  end

  defp put_season_localizations(season, titles) do
    episodes =
      Enum.map(season.episodes, fn episode ->
        Map.put(
          episode,
          :localizations,
          episode_localizations(episode.tmdb_episode_id, titles)
        )
      end)

    Map.put(season, :episodes, episodes)
  end

  defp episode_titles(seasons) do
    for season <- seasons,
        episode <- season.episodes,
        is_binary(episode.title),
        title = String.trim(episode.title),
        title != "",
        into: %{},
        do: {episode.tmdb_episode_id, title}
  end

  defp episode_localizations(tmdb_episode_id, titles) do
    for {locale, by_episode} <- titles,
        title = Map.get(by_episode, tmdb_episode_id),
        is_binary(title),
        into: %{},
        do: {locale, %{"title" => title}}
  end

  # `scene_numbering_group_id` is the series' operator-chosen scene group, or `nil` (a
  # brand-new series, or one with no alternate numbering configured). Its detail is fetched
  # here — alongside the rest of the identity data — so every TMDB call this function makes
  # happens before the caller's transaction opens (see
  # `Cinder.Catalog.SceneNumbering.set_scene_numbering_group/3`'s own pre-transaction fetch for
  # the interactive-save path). `scene_group_fetched_for` records which group id the detail
  # belongs to, so the refresh transaction can tell whether a racing save changed the group in
  # between (`Cinder.Catalog.SceneNumbering.sync_scene_coordinates_if_current/3`). Public (not
  # private) — also called from `Cinder.Catalog.SeriesRefresh.refresh_series/1`.
  @doc false
  def fetch_series_identity(tmdb_id, scene_numbering_group_id) do
    with {:ok, aliases} <- tmdb().get_series_alternative_titles(tmdb_id),
         {:ok, groups} <- tmdb().get_episode_groups(tmdb_id),
         {:ok, absolute_groups} <- fetch_absolute_groups(groups) do
      {:ok,
       %{
         aliases: aliases,
         absolute_groups: absolute_groups,
         scene_group_detail: scene_group_detail(absolute_groups, scene_numbering_group_id),
         scene_group_fetched_for: scene_numbering_group_id
       }}
    end
  end

  # The chosen scene group is sometimes also a type-2 Absolute group `fetch_absolute_groups/1`
  # just fetched in full above — both call sites hit the identical `get_episode_group` endpoint
  # for the same id, so the shape matches; reuse it instead of a second, redundant fetch.
  defp scene_group_detail(absolute_groups, group_id) do
    case Enum.find(absolute_groups, &(&1.id == group_id)) do
      nil -> SceneNumbering.fetch_scene_group_detail(group_id)
      detail -> detail
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

  # Public (not private) — also called from `Cinder.Catalog.SeriesRefresh.refresh_series/1`.
  @doc false
  def sync_series_identity(series, seasons, identity) do
    episode_lookup =
      if needs_episode_lookup?(seasons, identity) do
        episode_identity_lookup(series.id)
      else
        %{}
      end

    with {:ok, _} <-
           Identity.replace_provider_aliases(
             series,
             "tmdb",
             "alternative_titles",
             :inferred,
             identity.aliases
           ),
         :ok <- sync_absolute_coordinates(series, identity.absolute_groups, episode_lookup),
         :ok <- SceneNumbering.sync_scene_coordinates_if_current(series, identity, episode_lookup),
         {:ok, _} <- sync_tmdb_classifications(seasons, episode_lookup) do
      :ok
    end
  end

  # The "this series' episodes with a non-nil tmdb_episode_id" lookup shared by
  # sync_absolute_coordinates/3, `Cinder.Catalog.SceneNumbering`'s scene sync, and
  # sync_tmdb_classifications/2 — all run back-to-back inside sync_series_identity/3's one
  # transaction, and nothing between them changes an episode's tmdb_episode_id, so loading it
  # once (only when needs_episode_lookup?/2 says at least one of them needs it) and threading it
  # down is simpler than each hand-writing the same query, and one less round trip too. Returns
  # `%{tmdb_episode_id => episode_id}` directly — none of the readers ever needs more than the
  # Cinder episode id off it, unlike the preview path's
  # `Cinder.Catalog.SceneNumbering`-local `episode_lookup_from_tree/1`, which stays a
  # `%{tmdb_episode_id => %{episode_number:}}` shape instead (that preview only needs the episode
  # number). Public (not private) — also called from
  # `Cinder.Catalog.SceneNumbering.set_scene_numbering_group/3`'s interactive save path.
  @doc false
  def episode_identity_lookup(series_id) do
    Repo.all(
      from e in Episode,
        join: season in assoc(e, :season),
        where: season.series_id == ^series_id and not is_nil(e.tmdb_episode_id),
        select: {e.tmdb_episode_id, e.id}
    )
    |> Map.new()
  end

  # Decides whether sync_series_identity/3's shared episode_identity_lookup/1 query is worth
  # running at all: an absolute-numbering group to resolve, a scene group whose detail was
  # fetched, or a season/episode tree with any TMDB-sourced episode to classify. A series with
  # none of the three needs zero episode-lookup queries.
  defp needs_episode_lookup?(seasons, identity) do
    identity.absolute_groups != [] or
      not is_nil(identity.scene_group_detail) or
      Enum.any?(seasons, fn season -> Enum.any?(season.episodes, & &1.tmdb_episode_id) end)
  end

  defp sync_absolute_coordinates(series, absolute_groups, episode_lookup) do
    details_by_namespace = Map.new(absolute_groups, &{&1.id, &1})

    existing_namespaces =
      Repo.all(
        from c in Cinder.Catalog.EpisodeCoordinate,
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
        |> absolute_coordinate_attrs(episode_lookup)

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

  defp sync_tmdb_classifications(seasons, episode_lookup) do
    classifications =
      for season <- seasons,
          episode <- season.episodes,
          episode_id = episode_lookup[episode.tmdb_episode_id],
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
      localizations: Map.get(info, :localizations, %{}),
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
      Cinder.Catalog.broadcast_series(series_id_for_season(episode.season_id))
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
        case write_season_monitored(season, monitored?) do
          {:ok, updated} -> updated
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, season} <- result do
      Cinder.Catalog.broadcast_series(season.series_id)
      {:ok, season}
    end
  end

  defp write_season_monitored(season, monitored?) do
    with {:ok, updated} <-
           season |> Ecto.Changeset.change(monitored: monitored?) |> Repo.update() do
      Repo.update_all(from(e in Episode, where: e.season_id == ^season.id),
        set: [monitored: monitored?, updated_at: Cinder.Catalog.now()]
      )

      {:ok, updated}
    end
  end

  @doc """
  Re-applies a whole `monitor_strategy` (`:all` / `:future` / `:none`) across an already-added
  series' season/episode tree, using the same `monitored?/3` rule `add_series` uses at create
  time — so a title can be adopted with `:none` (catalogue + link on-disk files, grab nothing)
  and later handed to Cinder with `:future`.

  Updates the series, every season, and every episode in one transaction, then broadcasts
  `{:series_updated, id}`. This is a **full reset** to the create-time rule (like a fresh
  `add_series/2` with this strategy), not a merge: specials (non-`:regular` episodes) are set
  unmonitored regardless of strategy, and any manual per-episode toggle is overwritten. That reset
  is what makes `:none` actually stop the series — the leaf `episode.monitored` flag is what the TV
  sweep reads (season/series `monitored` doesn't gate it). Returns `{:ok, series}`,
  `{:error, :invalid_monitor_strategy}` for an unknown strategy, or `{:error, changeset}` on a
  write failure.
  """
  def set_series_monitor_strategy(%Series{} = series, strategy) do
    if strategy in Series.monitor_strategies() do
      reapply_monitor_strategy(series, strategy)
    else
      {:error, :invalid_monitor_strategy}
    end
  end

  defp reapply_monitor_strategy(series, strategy) do
    tree_monitored = strategy != :none

    result =
      Repo.transaction(fn ->
        case series
             |> Ecto.Changeset.change(monitored: tree_monitored, monitor_strategy: strategy)
             |> Repo.update() do
          {:ok, series} ->
            reapply_tree_monitoring(series, strategy, tree_monitored)
            series

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    with {:ok, series} <- result do
      Cinder.Catalog.broadcast_series(series.id)
      {:ok, series}
    end
  end

  defp reapply_tree_monitoring(series, strategy, tree_monitored) do
    today = Date.utc_today()
    season_ids = Repo.all(from(s in Season, where: s.series_id == ^series.id, select: s.id))

    Repo.update_all(from(s in Season, where: s.id in ^season_ids),
      set: [monitored: tree_monitored, updated_at: Cinder.Catalog.now()]
    )

    # Episode monitored depends on per-row classification + air_date, so partition the ids by the
    # shared monitored?/3 rule and bulk-write each group (≤2 update_alls) rather than re-encoding
    # that rule in SQL — one source of truth with create_series.
    from(e in Episode,
      where: e.season_id in ^season_ids,
      select: {e.id, e.classification, e.air_date}
    )
    |> Repo.all()
    |> Enum.group_by(
      fn {_id, classification, air_date} ->
        classification == :regular and monitored?(strategy, air_date, today)
      end,
      fn {id, _classification, _air_date} -> id end
    )
    |> Enum.each(fn {monitored?, ids} ->
      Repo.update_all(from(e in Episode, where: e.id in ^ids),
        set: [monitored: monitored?, updated_at: Cinder.Catalog.now()]
      )
    end)
  end

  @doc """
  The SQL-expressible wanted set: monitored episodes with no file and no active grab whose
  `air_date` has passed (set and `<= today`). Preloads `season: :series` for the poller's
  search + season-grouping. Backoff/bound filtering (search_attempts, retry window) is applied
  by the TV poller, matching the movie poller's split. Gated on the leaf `episode.monitored`
  flag (the cascade/add keep it the single source of truth).

  Regular episodes keep the existing positive season/episode-number gate. Explicitly monitored,
  classified Anime story specials and recaps share the common missing/air-date predicates; an
  unclassified Anime special or a pure `:extra` stays excluded. A Standard (non-Anime) Season 00
  row shares the same common predicates with no classification gate — an operator who explicitly
  monitors a Standard special wants it searched exactly like a regular episode.
  """
  def wanted_episodes do
    Repo.all(from e in wanted_episodes_query(), preload: [season: :series])
  end

  @doc """
  Episodes a season-level manual search may replace or fill: ungrabbed available episodes
  (monitored or not) plus the normal wanted set. Unlike `wanted_episodes/0`, this is operator-only
  input and is never consumed by the automatic sweep.
  """
  def manual_search_episodes(series_id, season_number) do
    episodes =
      Repo.all(
        from e in Episode,
          join: s in assoc(e, :season),
          where:
            s.series_id == ^series_id and s.season_number == ^season_number and is_nil(e.grab_id),
          preload: [season: :series]
      )

    case episodes do
      [%{season: %{series: series}} | _] ->
        profile = Cinder.Catalog.media_profile_summary(series)

        Enum.filter(
          episodes,
          &(&1.file_path not in [nil, ""] or episode_searchable?(&1, profile))
        )

      [] ->
        []
    end
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

  # Public (not private) — also called from `Cinder.Catalog.Grabs.finish_grab/3`'s season
  # availability announce.
  @doc false
  def available_seasons_query(today) do
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

  @doc """
  Per-season progress keyed by `{series tmdb_id, season_number}`: how many episodes have a file
  (`available`), the season's total episode count, and whether any episode is mid-download (an
  active `grab_id`). Drives the requester-facing "X of Y episodes" indicator on `/my-requests`
  while a season is still filling in — the partial-progress complement to the terminal
  `available_season_keys/0`, which only reports fully-landed seasons. Season 0 (specials) is
  excluded, matching `available_seasons_query/1`.
  """
  def season_progress_keys do
    from(e in Episode,
      join: s in assoc(e, :season),
      join: sr in assoc(s, :series),
      where: s.season_number > 0,
      group_by: [sr.tmdb_id, s.season_number],
      select: {
        sr.tmdb_id,
        s.season_number,
        count(e.id),
        filter(count(e.id), not is_nil(e.file_path)),
        filter(count(e.id), not is_nil(e.grab_id))
      }
    )
    |> Repo.all()
    |> Map.new(fn {tmdb_id, season_number, total, available, downloading} ->
      {{tmdb_id, season_number},
       %{total: total, available: available, downloading: downloading > 0}}
    end)
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
  Re-queues every search-parked episode whose row has been untouched since `cutoff`, by zeroing
  its `search_attempts` — the automatic counterpart to `search_episode_now/1`, driven by
  `Cinder.Catalog.Rehunter`. Eligibility reuses `wanted_episodes_query/0` verbatim, so the set can
  never drift from what the TV sweep actually searches.

  One `update_all` (no join — the ids are selected first, since SQLite can't UPDATE ... FROM), then
  one `{:series_updated, id}` broadcast per affected series so open views re-render the state
  change from `:search_parked` back to `:wanted`. `updated_at` is deliberately left alone, matching
  `set_series_language/2`'s reset: the sweep's own attempt bump is what re-establishes the backoff
  clock. Returns the number of episodes re-queued.
  """
  def rehunt_parked_episodes(%DateTime{} = cutoff) do
    parked =
      Repo.all(
        from([e, s] in wanted_episodes_query(),
          where: e.search_attempts >= @max_search_attempts and e.updated_at < ^cutoff,
          select: {e.id, s.series_id}
        )
      )

    case Enum.unzip(parked) do
      {[], _} ->
        0

      {ids, series_ids} ->
        {count, _} =
          Repo.update_all(from(e in Episode, where: e.id in ^ids), set: [search_attempts: 0])

        series_ids |> Enum.uniq() |> Enum.each(&Cinder.Catalog.broadcast_series/1)
        count
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

          episode_searchable?(
            episode,
            Cinder.Catalog.media_profile_summary(episode.season.series)
          ) ->
            # Manual re-search: give any :stalled-reaped release for this series a fresh chance.
            Cinder.Catalog.clear_stalled_blocklist(series: episode.season.series.id)
            Cinder.Catalog.transition_episode(episode, %{search_attempts: 0})

          true ->
            {:error, :not_searchable}
        end

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Re-queues every still-wanted episode of one `season` (zeroes their `search_attempts`)."
  def search_season_now(%Season{id: season_id}) do
    episodes = wanted_episodes() |> Enum.filter(&(&1.season_id == season_id))

    # Manual re-search: give any :stalled-reaped release for this series a fresh chance.
    case episodes do
      [%{season: %{series: %{id: series_id}}} | _] ->
        Cinder.Catalog.clear_stalled_blocklist(series: series_id)

      _ ->
        :ok
    end

    Enum.each(episodes, &Cinder.Catalog.transition_episode(&1, %{search_attempts: 0}))
  end

  defp wanted_episodes_query do
    today = Date.utc_today()

    from e in Episode,
      join: s in assoc(e, :season),
      join: series in assoc(s, :series),
      where:
        e.monitored == true and is_nil(e.file_path) and is_nil(e.grab_id) and
          not is_nil(e.air_date) and e.air_date <= ^today,
      where: ^wanted_kind_dynamic()
  end

  # The season/classification half of `wanted_episodes_query/0`'s eligibility, split out as a
  # `dynamic` so the caller's own complexity stays flat — shared verbatim by `upcoming_episodes/0`
  # so the two can't drift.
  defp wanted_kind_dynamic do
    dynamic(
      [e, s, series],
      (s.season_number > 0 and e.episode_number > 0) or
        (series.media_profile == :anime and e.classification in [:story_special, :recap]) or
        (series.media_profile != :anime and s.season_number == 0 and e.episode_number > 0)
    )
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

    common? and episode_kind_wanted?(episode, season, profile)
  end

  # The season/classification half of `episode_searchable?/3`'s eligibility, split out to keep
  # the caller's own complexity flat. Mirrors `wanted_kind_dynamic/0`'s SQL predicate exactly.
  defp episode_kind_wanted?(episode, season, profile) do
    regular? = season.season_number > 0 and episode.episode_number > 0
    special? = profile.effective == :anime and episode.classification in [:story_special, :recap]

    standard_special? =
      profile.effective != :anime and season.season_number == 0 and episode.episode_number > 0

    regular? or special? or standard_special?
  end

  @doc """
  Monitored, dated episodes in a calendar window (`today - 7 .. today + 90`), ordered by air date,
  with `season: :series` preloaded for the calendar view. A season 0 row is included only when
  it's actually search-eligible — a Standard-profile explicit S00 monitor, or an Anime-classified
  story special/recap — mirroring `wanted_episodes_query/0`, so the view's derived "wanted" badge
  stays honest for every row, not just regular episodes.
  """
  def upcoming_episodes do
    today = Date.utc_today()
    from_date = Date.add(today, -7)
    to_date = Date.add(today, 90)

    Repo.all(
      from e in Episode,
        join: s in assoc(e, :season),
        join: series in assoc(s, :series),
        where:
          e.monitored and not is_nil(e.air_date) and e.air_date >= ^from_date and
            e.air_date <= ^to_date,
        where: ^wanted_kind_dynamic(),
        order_by: [asc: e.air_date],
        preload: [season: :series]
    )
  end

  defp series_id_for_season(season_id),
    do: Repo.one(from s in Season, where: s.id == ^season_id, select: s.series_id)

  # Resolve the impl at runtime — see `Cinder.Catalog.Discovery`'s copy for why not compile_env!.
  defp tmdb, do: Application.fetch_env!(:cinder, :tmdb)
end
