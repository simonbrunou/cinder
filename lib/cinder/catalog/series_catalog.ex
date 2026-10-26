defmodule Cinder.Catalog.SeriesCatalog do
  @moduledoc """
  Series rows: TMDB-backed creation (`add_series/2`, find-or-create for a requested season),
  the season/episode tree and its monitoring toggles, season availability, and the
  identity-sync machinery (TMDB aliases + absolute/scene episode-group coordinates) shared by
  creation and refresh. What the TV sweep searches for is `Cinder.Catalog.EpisodeSearch`.
  Changes are announced through `Cinder.Catalog.Events`.
  """
  import Ecto.Query
  require Logger

  alias Cinder.Catalog.{
    Episode,
    Episodes,
    Events,
    Identity,
    MediaProfiles,
    SceneNumbering,
    Season,
    Series
  }

  alias Cinder.Locales
  alias Cinder.{Repo, Settings}

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

  @doc "Episodes with an imported file, season+series+scene-coordinates preloaded (subtitle-fetch candidates)."
  def list_episodes_with_file do
    Repo.all(
      from e in Episode,
        where: not is_nil(e.file_path) or fragment("json_array_length(?) > 0", e.part_file_paths),
        preload: [:episode_coordinates, season: :series]
    )
  end

  @doc """
  The same list narrowed to one series — what a standard-TV import matches its *unclaimed* videos
  against, to tell a season pack's already-held episodes from genuinely unknown extras (#251).
  Scoping to the series matters: `match_arm/2` compares season and episode numbers only, so an
  unscoped list would let one show's "S01E05" claim another's.
  """
  def list_episodes_with_file(series_id) do
    Repo.all(
      from e in Episode,
        join: s in assoc(e, :season),
        where: s.series_id == ^series_id and not is_nil(e.file_path),
        preload: [:episode_coordinates, season: :series]
    )
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

  Deduplicates by the complete primary-plus-parts path bundle. `Cinder.Library.stage_episodes/3`
  gives one multi-episode source **one** destination that every covered episode references, and
  `update_imported_episode!/5` writes the full imported size to each of those rows — so a bare
  `sum(imported_size)` double-counts a double-episode file. A part-only bundle left by a partial
  unlink still counts until its final path is removed.

  Two known inexactnesses, recorded rather than fixed:

    * `Cinder.Library.stage_anime_all/4` groups by `{source, season_number}` rather than by source
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
  `Cinder.Catalog.MetadataRefresh.refresh_series/1` (the periodic Refresher). Returns
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
    profile_id = Keyword.get(opts, :profile_id)
    before_write = Keyword.get(opts, :before_write, fn -> :ok end)

    if strategy in Series.monitor_strategies() and is_function(before_write, 0) do
      case get_series_by_tmdb_id(tmdb_id) do
        %Series{} = series ->
          {:ok, series}

        nil ->
          create_series(
            tmdb_id,
            strategy,
            preferred,
            media_profile,
            profile_id,
            before_write
          )
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
      Events.series_updated(updated.id)
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
       do: MediaProfiles.set_series_language_in_transaction(series, preferred)

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

  defp create_series(tmdb_id, strategy, preferred, media_profile, profile_id, before_write) do
    with {:ok, {:new, ^tmdb_id, attrs, seasons, identity}} <-
           prepare_series(tmdb_id, strategy, preferred, media_profile, profile_id) do
      insert_series(tmdb_id, attrs, seasons, identity, before_write)
    end
  end

  defp prepare_series(tmdb_id, strategy, preferred, media_profile, profile_id \\ nil) do
    with {:ok, info} <- tmdb().get_series(tmdb_id),
         {:ok, seasons} <- fetch_seasons(tmdb_id, info.seasons),
         seasons = put_episode_localizations(tmdb_id, seasons),
         # A brand-new series has no scene_numbering_group_id yet (create_changeset doesn't
         # cast it), so there's nothing to pre-fetch here.
         {:ok, identity} <- fetch_series_identity(tmdb_id, nil) do
      attrs =
        info
        |> series_attrs(seasons, strategy, preferred, media_profile)
        |> Map.put(:profile_id, profile_id)

      {:ok, {:new, tmdb_id, attrs, seasons, identity}}
    end
  end

  defp insert_series(tmdb_id, attrs, seasons, identity, before_write) do
    result =
      Repo.transaction(
        fn ->
          with :ok <- before_write.(),
               {:ok, series} <- write_new_series(attrs, seasons, identity) do
            series
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end,
        mode: :immediate
      )

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
  # `Cinder.Catalog.MetadataRefresh.refresh_series/1`.
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
  # private) — also called from `Cinder.Catalog.MetadataRefresh.refresh_series/1`.
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
        {:ok, %{id: id, type: 2} = detail} when id == group.id ->
          {:cont, {:ok, [detail | details]}}

        {:ok, _mismatched_detail} ->
          {:halt, {:error, :group_fetch_failed}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, details} -> {:ok, Enum.reverse(details)}
      error -> error
    end
  end

  # Public (not private) — also called from `Cinder.Catalog.MetadataRefresh.refresh_series/1`.
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
    today = Settings.household_date()

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

  @doc """
  Sets one episode's `monitored` flag and broadcasts `{:series_updated, series_id}`. Unmonitoring
  the series' last monitored episode lifts its anime hold (`lift_unmonitored_anime_hold/1`).
  """
  def set_episode_monitored(%Episode{} = episode, monitored?) do
    with {:ok, episode} <-
           episode |> Ecto.Changeset.change(monitored: monitored?) |> Repo.update() do
      series_id = Episodes.series_id(episode)
      Events.series_updated(series_id)
      unless monitored?, do: lift_unmonitored_anime_hold(series_id)
      {:ok, episode}
    end
  end

  @doc """
  Lifts a series' anime hold once it monitors no episode, as the `:none` strategy does: no sweep
  visits such a series to decide the hold again. Call after the commit of a write that unmonitors
  episodes, since the lift announces itself. Returns `:ok`.
  """
  def lift_unmonitored_anime_hold(series_id) do
    held =
      Repo.one(from s in Series, where: s.id == ^series_id and not is_nil(s.anime_hold_reason))

    monitors_any? =
      Repo.exists?(
        from e in Episode,
          join: s in Season,
          on: e.season_id == s.id,
          where: s.series_id == ^series_id and e.monitored == true
      )

    if held && not monitors_any?, do: MediaProfiles.set_anime_hold(held, nil)
    :ok
  end

  @doc """
  Sets a season's `monitored` flag and cascades it to every episode in one transaction, then
  broadcasts `{:series_updated, series_id}`. Unmonitoring the series' last monitored episode lifts
  its anime hold (`lift_unmonitored_anime_hold/1`).
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
      Events.series_updated(season.series_id)
      unless monitored?, do: lift_unmonitored_anime_hold(season.series_id)
      {:ok, season}
    end
  end

  defp write_season_monitored(season, monitored?) do
    with {:ok, updated} <-
           season |> Ecto.Changeset.change(monitored: monitored?) |> Repo.update() do
      Repo.update_all(from(e in Episode, where: e.season_id == ^season.id),
        set: [monitored: monitored?, updated_at: DateTime.utc_now(:second)]
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

  # `:none` also lifts an anime hold: no sweep visits a series monitoring nothing to re-evaluate it,
  # so it would otherwise need attention forever. Forced, so a caller's struct read before the
  # sweep set the hold still clears it. Another strategy can monitor nothing too (`:future` on an
  # ended series), so the lift check runs after its commit.
  defp reapply_monitor_strategy(series, strategy) do
    tree_monitored = strategy != :none

    changeset =
      Ecto.Changeset.change(series, monitored: tree_monitored, monitor_strategy: strategy)

    changeset =
      if tree_monitored,
        do: changeset,
        else: Ecto.Changeset.force_change(changeset, :anime_hold_reason, nil)

    result =
      Repo.transaction(fn ->
        case Repo.update(changeset) do
          {:ok, series} ->
            reapply_tree_monitoring(series, strategy, tree_monitored)
            series

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    with {:ok, series} <- result do
      Events.series_updated(series.id)
      if tree_monitored, do: lift_unmonitored_anime_hold(series.id)
      {:ok, series}
    end
  end

  defp reapply_tree_monitoring(series, strategy, tree_monitored) do
    today = Settings.household_date()
    season_ids = Repo.all(from(s in Season, where: s.series_id == ^series.id, select: s.id))

    Repo.update_all(from(s in Season, where: s.id in ^season_ids),
      set: [monitored: tree_monitored, updated_at: DateTime.utc_now(:second)]
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
        set: [monitored: monitored?, updated_at: DateTime.utc_now(:second)]
      )
    end)
  end

  @doc """
  `{series tmdb_id, season_number}` pairs whose content has fully landed: at least one
  episode file, and no aired episode still missing one — monitored or not, because a
  `:future`-strategy season with only its newest episode imported must NOT read Available
  (that would hide the Request affordance for a season that's 90% absent). Drives the
  requester-facing season badges — availability outranks a stale request status
  (mirroring the movie `title_state` precedence), otherwise a fully imported season
  reads "Approved"/"Denied" forever. Pass a `tmdb_id`, or a list of them, to scope the read.
  """
  def available_season_keys(tmdb_id \\ nil) do
    Settings.household_date()
    |> available_seasons_query()
    |> scope_to_series(tmdb_id)
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
  excluded, matching `available_seasons_query/1`. Pass a `tmdb_id`, or a list of them, to scope
  the read.
  """
  def season_progress_keys(tmdb_id \\ nil) do
    query =
      from(e in Episode,
        join: s in assoc(e, :season),
        join: sr in assoc(s, :series),
        where: s.season_number > 0
      )
      |> scope_to_series(tmdb_id)

    from([e, s, sr] in query,
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

  # `nil` reads every series. A list lets `Cinder.Requests.Target` batch one read across the
  # series a page's requests name.
  defp scope_to_series(query, nil), do: query

  defp scope_to_series(query, tmdb_ids) when is_list(tmdb_ids),
    do: where(query, [_e, _s, sr], sr.tmdb_id in ^tmdb_ids)

  defp scope_to_series(query, tmdb_id), do: where(query, [_e, _s, sr], sr.tmdb_id == ^tmdb_id)

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

  # Resolve the impl at runtime — see `Cinder.Catalog.Discovery`'s copy for why not compile_env!.
  defp tmdb, do: Application.fetch_env!(:cinder, :tmdb)
end
