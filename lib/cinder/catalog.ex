defmodule Cinder.Catalog do
  @moduledoc """
  The catalog's one name for code outside `lib/cinder/catalog/`: every function here delegates
  to the concept module that owns it, and this module holds no implementation of its own.
  Nothing under `lib/cinder/catalog/` calls it; a concept calls the module it needs directly.
  `test/code_health_test.exs` fences both rules.

  Each section below names its owner in its `to:`. Callers outside the catalog also name some
  modules directly, with no facade name: every movie status write is a
  `Cinder.Catalog.MovieLifecycle` verb, a change announced after the caller's own commit goes
  through `Cinder.Catalog.Events`, and modules with an interface of their own (such as
  `Cinder.Catalog.Attention`) are called as they are. The concept map, kernel included, is in
  `docs/agents/architecture.md` ("The catalog is split by concept").
  """

  alias Cinder.Catalog.{
    Adoption,
    BlockedReleases,
    Discovery,
    Episodes,
    EpisodeSearch,
    Events,
    Grabs,
    Identity,
    LibraryVisibility,
    ManualGrab,
    MediaProfiles,
    MediaServerReconciliation,
    MetadataRefresh,
    MovieCatalog,
    Profiles,
    SceneNumbering,
    SeriesCatalog,
    TitleDeletion
  }

  ## Announcements

  defdelegate subscribe, to: Events, as: :subscribe_movies
  defdelegate subscribe_series, to: Events

  ## Discovery

  defdelegate get_movie(tmdb_id), to: Discovery
  defdelegate search_movies(query), to: Discovery
  defdelegate search_movies(query, locale), to: Discovery
  defdelegate search_tv(query), to: Discovery
  defdelegate search_tv(query, locale), to: Discovery
  defdelegate search_discover(query), to: Discovery
  defdelegate search_discover(query, locale), to: Discovery
  defdelegate trending(locale), to: Discovery
  defdelegate popular_movies(locale), to: Discovery
  defdelegate top_rated_movies(locale), to: Discovery
  defdelegate now_playing_movies(locale), to: Discovery
  defdelegate popular_tv(locale), to: Discovery
  defdelegate top_rated_tv(locale), to: Discovery
  defdelegate movies_by_genre(genre_id, locale), to: Discovery
  defdelegate tv_by_genre(genre_id, locale), to: Discovery
  defdelegate recommended_movies(tmdb_id, locale), to: Discovery
  defdelegate recommended_tv(tmdb_id, locale), to: Discovery
  defdelegate get_person(tmdb_id, locale), to: Discovery
  defdelegate get_collection(tmdb_id, locale), to: Discovery
  defdelegate tmdb_series(tmdb_id), to: Discovery
  defdelegate localized_title(media, locale), to: Discovery
  defdelegate localized_overview(media, locale), to: Discovery

  ## Movie rows

  defdelegate add_movie(attrs), to: MovieCatalog
  defdelegate list_movies(), to: MovieCatalog
  defdelegate movie_status_map(), to: MovieCatalog
  defdelegate movie_status_counts(), to: MovieCatalog
  defdelegate recent_movies(limit), to: MovieCatalog
  defdelegate get_movie_by_id(id), to: MovieCatalog
  defdelegate get_movie_by_tmdb_id(tmdb_id), to: MovieCatalog
  defdelegate list_by_status(status), to: MovieCatalog
  defdelegate list_available_movies_with_file(), to: MovieCatalog
  defdelegate find_or_create_at_requested(attrs, aliases \\ []), to: MovieCatalog
  defdelegate prepare_requested_movie(attrs), to: MovieCatalog

  ## Series rows, the tree and monitoring

  defdelegate get_series_by_tmdb_id(tmdb_id), to: SeriesCatalog
  defdelegate list_series(), to: SeriesCatalog
  defdelegate count_series(), to: SeriesCatalog
  defdelegate series_library_sizes(), to: SeriesCatalog
  defdelegate add_series(tmdb_id), to: SeriesCatalog
  defdelegate add_series(tmdb_id, opts), to: SeriesCatalog
  defdelegate find_or_create_series_at_requested(tmdb_id, season_number), to: SeriesCatalog

  defdelegate find_or_create_series_at_requested(tmdb_id, season_number, preferred),
    to: SeriesCatalog

  defdelegate find_or_create_series_at_requested(
                tmdb_id,
                season_number,
                preferred,
                media_profile
              ),
              to: SeriesCatalog

  defdelegate prepare_requested_series(tmdb_id, preferred, media_profile), to: SeriesCatalog

  defdelegate persist_requested_series(prepared, season_number, preferred, media_profile),
    to: SeriesCatalog

  defdelegate get_series_with_tree(id), to: SeriesCatalog
  defdelegate get_single_series_for_episode_ids(episode_ids), to: SeriesCatalog
  defdelegate set_episode_monitored(episode, monitored?), to: SeriesCatalog
  defdelegate set_season_monitored(season, monitored?), to: SeriesCatalog
  defdelegate set_series_monitor_strategy(series, strategy), to: SeriesCatalog
  defdelegate list_episodes_with_file(), to: SeriesCatalog
  defdelegate list_episodes_with_file(series_id), to: SeriesCatalog
  defdelegate available_season_keys(), to: SeriesCatalog
  defdelegate available_season_keys(tmdb_id), to: SeriesCatalog
  defdelegate season_progress_keys(tmdb_id \\ nil), to: SeriesCatalog
  defdelegate count_episodes(series_id, season_number), to: SeriesCatalog

  ## Episodes: state, budget and the pipeline write

  defdelegate transition_episode(episode, attrs, opts \\ []), to: Episodes, as: :transition
  defdelegate episode_state(episode), to: Episodes, as: :state
  defdelegate episode_state(episode, today), to: Episodes, as: :state
  defdelegate max_search_attempts(), to: Episodes

  ## Episode search

  defdelegate wanted_episodes(), to: EpisodeSearch
  defdelegate count_wanted_episodes(), to: EpisodeSearch
  defdelegate count_wanted_episodes(series_id, season_number), to: EpisodeSearch
  defdelegate manual_search_episodes(series_id, season_number), to: EpisodeSearch
  defdelegate season_acquisition_context(series, season_number), to: EpisodeSearch
  defdelegate season_manual_searchable?(season, profile), to: EpisodeSearch
  defdelegate episode_searchable?(episode, profile), to: EpisodeSearch
  defdelegate episode_kind_wanted?(episode, season, profile), to: EpisodeSearch
  defdelegate search_episode_now(episode), to: EpisodeSearch
  defdelegate search_season_now(season), to: EpisodeSearch
  defdelegate increment_search_attempts(episode_ids), to: EpisodeSearch
  defdelegate upcoming_episodes(), to: EpisodeSearch

  ## A title's preferences

  defdelegate set_media_profile(title, profile), to: MediaProfiles
  defdelegate apply_confirmed_media(media, profile, preferred), to: MediaProfiles

  defdelegate apply_confirmed_media(media, profile, preferred, pre_request_profile),
    to: MediaProfiles

  defdelegate set_movie_language(movie, language), to: MediaProfiles
  defdelegate set_series_language(series, language), to: MediaProfiles
  defdelegate set_anime_hold(title, reason), to: MediaProfiles
  defdelegate list_anime_held_series(), to: MediaProfiles
  defdelegate media_profile_summary(title), to: MediaProfiles
  defdelegate movie_acquisition_context(movie), to: MediaProfiles
  defdelegate anime_series_acquisition_context(series), to: MediaProfiles
  defdelegate list_profiles(), to: Profiles
  defdelegate list_profiles(kind), to: Profiles
  defdelegate get_profile(id), to: Profiles
  defdelegate create_profile(attrs), to: Profiles
  defdelegate update_profile(profile, attrs), to: Profiles
  defdelegate delete_profile(profile), to: Profiles
  defdelegate assign_profile(title, profile, opts \\ []), to: Profiles

  ## Aliases and episode coordinates

  defdelegate list_title_aliases(owner), to: Identity, as: :list_aliases
  defdelegate save_manual_alias(owner, attrs), to: Identity
  defdelegate update_manual_alias(owner, alias_id, attrs), to: Identity
  defdelegate delete_manual_alias(owner, alias_id), to: Identity
  defdelegate list_episode_coordinates(series), to: Identity, as: :list_coordinates
  defdelegate list_episode_groups(series), to: SceneNumbering
  defdelegate get_episode_group(group_id), to: SceneNumbering
  defdelegate preview_scene_mapping(group_detail, series), to: SceneNumbering
  defdelegate set_scene_numbering_group(series, group_id), to: SceneNumbering
  defdelegate set_scene_numbering_group(series, group_id, opts), to: SceneNumbering
  defdelegate preview_scene_offset(series, from, delta), to: SceneNumbering
  defdelegate save_scene_offset_coordinates(series, from, delta), to: SceneNumbering

  ## Descriptive data and the library

  defdelegate refresh_series(series), to: MetadataRefresh
  defdelegate enrich_movie(movie), to: MetadataRefresh
  defdelegate enrich_series(series), to: MetadataRefresh
  defdelegate set_media_info(record, quality), to: MetadataRefresh
  defdelegate dot_folder_files(), to: LibraryVisibility

  defdelegate reconcile_media_server_items(kind, items),
    to: MediaServerReconciliation,
    as: :reconcile

  defdelegate adopt_episode_files(actions), to: Adoption

  defdelegate adopt_series_files(series, actions, profile_id, legacy_handling, validator),
    to: Adoption

  ## Deleting and cancelling titles

  defdelegate delete_movie(movie, actor, opts \\ []), to: TitleDeletion
  defdelegate delete_series(series, actor), to: TitleDeletion
  defdelegate delete_series(series, actor, opts), to: TitleDeletion
  defdelegate cancel_series(series, actor), to: TitleDeletion
  defdelegate delete_episode_file(episode, actor), to: TitleDeletion
  defdelegate delete_episode_file(episode, actor, opts), to: TitleDeletion
  defdelegate delete_season_files(season, actor), to: TitleDeletion
  defdelegate delete_season_files(season, actor, opts), to: TitleDeletion

  ## Manual grabs

  defdelegate manual_grab_movie(movie, release), to: ManualGrab
  defdelegate manual_grab_tv(series, season_number, release), to: ManualGrab

  ## The TV grab lifecycle

  defdelegate create_grab(download_id, protocol, episode_ids), to: Grabs
  defdelegate create_grab(download_id, protocol, episode_ids, release_title), to: Grabs
  defdelegate create_grab(download_id, protocol, episode_ids, release_title, opts), to: Grabs
  defdelegate create_grab_from_intent(intent), to: Grabs
  defdelegate record_mapping_result(grab, preflight_result), to: Grabs
  defdelegate update_grab_download_metrics(grab, attrs), to: Grabs
  defdelegate mark_grab_downloaded(grab, content_path), to: Grabs
  defdelegate increment_grab_attempts(grab), to: Grabs
  defdelegate hold_grab_verification(grab), to: Grabs
  defdelegate retry_grab_verification(grab), to: Grabs
  defdelegate retry_grab_mapping(grab), to: Grabs
  defdelegate import_grab_anyway(grab, actor), to: Grabs
  defdelegate reject_grab_release(expected, evidence), to: Grabs
  defdelegate cancel_grab(grab), to: Grabs
  defdelegate cancel_mapping_grab(grab), to: Grabs
  defdelegate commit_grab_imports(grab, imported, residuals), to: Grabs
  defdelegate commit_grab_imports(grab, imported, residuals, stage_ids), to: Grabs
  defdelegate close_grab(grab), to: Grabs
  defdelegate decide_grab_file(file, episode, decision, stage), to: Grabs
  defdelegate discard_grab_file(file), to: Grabs
  defdelegate finish_grab(grab), to: Grabs
  defdelegate finish_grab(grab, imported), to: Grabs
  defdelegate finish_grab(grab, imported, stage_ids), to: Grabs
  defdelegate park_grab(grab), to: Grabs
  defdelegate park_grab_and_remove(grab), to: Grabs
  defdelegate reap_stalled_grab(grab), to: Grabs
  defdelegate grab_cleanup_spec(grab, episode_ids), to: Grabs
  defdelegate list_grabs_downloading(), to: Grabs
  defdelegate count_grabs_downloading(), to: Grabs
  defdelegate list_grabs_downloaded(), to: Grabs
  defdelegate list_grabs(), to: Grabs
  defdelegate unresolved_grab_files(grab), to: Grabs
  defdelegate list_mapping_grabs_for_series(series_id), to: Grabs
  defdelegate get_grab(id), to: Grabs

  ## The release blocklist

  defdelegate block_release(movie, reason), to: BlockedReleases
  defdelegate block_release_and_confirm(movie, reason), to: BlockedReleases
  defdelegate block_grab_release(grab, reason), to: Grabs
  defdelegate clear_stalled_blocklist(scope), to: BlockedReleases
  defdelegate blocked_release_titles(movie), to: BlockedReleases
  defdelegate blocked_release_titles_for_series(series_id), to: BlockedReleases
  defdelegate blocked_release_titles_for_series(series_id, opts), to: BlockedReleases
end
