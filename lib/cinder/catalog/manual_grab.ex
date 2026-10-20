defmodule Cinder.Catalog.ManualGrab do
  @moduledoc """
  A release the operator picked on a manual search panel: the movie grab and the season grab,
  with the checks that keep an operator-chosen release from reserving episodes it does not name
  (anime mapping safety, standard numbering). Both hand the release to `Cinder.Download`, which
  submits it and creates the grab through `Cinder.Catalog.Grabs`.
  """
  alias Cinder.Acquisition.{Anime, Release}
  alias Cinder.Catalog.{Attention, EpisodeSearch, MediaProfiles, Movie, Series}
  alias Cinder.Download
  alias Cinder.Download.Intent
  alias Cinder.Repo

  @doc """
  Grabs a specific user-chosen `release` for `movie`. An `:available` movie enters `:upgrading`
  (its library `file_path` and `imported_*` are preserved — the poller's upgrade clause swaps the
  file only on a successful re-import). A parked movie that is not on a verification hold enters
  `:downloading` on the normal import path. A movie that does not offer `:manual_search`
  (`Attention.offers?/2`) returns `{:error, :not_grabbable}` (rejecting
  in-flight/`:upgrading`/`:cancelled`, which also blocks a double-click). A movie deleted
  mid-action surfaces `{:error, :stale_entry}`.
  """
  def manual_grab_movie(%Movie{} = movie, %Release{} = release) do
    if Attention.offers?(movie, :manual_search),
      do: Download.grab_movie(movie, release),
      else: {:error, :not_grabbable}
  end

  @doc """
  Grabs a user-chosen `release` for one `season_number` of `series`. Recomputes the season's
  manually searchable episodes server-side (don't trust a stale panel snapshot) and creates the
  grab over exactly the missing or available episodes the release covers (`episodes: nil` = a
  whole-season pack covers them all). `create_grab/5` never links an episode that already has a
  grab, rolling back if any was taken meanwhile so a concurrent sweep grab can't be double-linked;
  `Download.reconcile_episodes/1` flattens that to `{:error, :no_episodes_linked}` here.
  `{:error, :nothing_wanted}` when the season has nothing to grab.
  """
  def manual_grab_tv(%Series{id: series_id}, season_number, %Release{} = release) do
    case manual_grab_tv_state(series_id, season_number) do
      {:ok, {:anime, current}} ->
        manual_grab_anime_tv(current, release)

      {:ok, {:standard, current_series}} ->
        manual_grab_standard_tv(current_series, season_number, release)

      {:error, :stale_entry} ->
        {:error, :stale_entry}
    end
  end

  defp manual_grab_tv_state(series_id, season_number) do
    Repo.transaction(fn ->
      case Repo.get(Series, series_id) do
        nil -> Repo.rollback(:stale_entry)
        current_series -> current_manual_grab_state(current_series, season_number)
      end
    end)
  end

  defp current_manual_grab_state(%Series{id: series_id} = series, season_number) do
    case MediaProfiles.media_profile_summary(series).effective do
      :anime -> {:anime, anime_manual_grab_context(series_id, season_number)}
      :standard -> {:standard, series}
    end
  end

  defp manual_grab_anime_tv(
         %{context: _context, candidate_ids: _candidate_ids} = current,
         %Release{} = release
       ) do
    if safe_anime_mapping?(release) do
      do_manual_grab_anime_tv(current, release)
    else
      {:error, :unsafe_anime_mapping}
    end
  end

  defp do_manual_grab_anime_tv(%{context: context, candidate_ids: candidate_ids}, release) do
    [current_release] =
      Anime.episode_candidates([release], context, candidate_ids)

    with true <- safe_anime_mapping?(current_release),
         true <-
           MapSet.subset?(
             MapSet.new(current_release.resolved_episode_ids),
             MapSet.new(candidate_ids)
           ) do
      case grab_and_create_grab(current_release, current_release.resolved_episode_ids) do
        {:error, :invalid_mapping_snapshot} -> {:error, :unsafe_anime_mapping}
        result -> result
      end
    else
      false -> {:error, :unsafe_anime_mapping}
    end
  end

  defp safe_anime_mapping?(%Release{
         resolved_episode_ids: ids,
         mapping_snapshot: %{"version" => version} = snapshot
       })
       when version in [2, 3] and is_list(ids) and ids != [] do
    kind = if length(ids) == 1, do: :episode, else: :season_pack
    Intent.valid_mapping_snapshot?(snapshot, kind, ids)
  end

  defp safe_anime_mapping?(_release), do: false

  defp manual_grab_standard_tv(_series, _season_number, %Release{mapping_snapshot: snapshot})
       when not is_nil(snapshot),
       do: {:error, :unsafe_anime_mapping}

  defp manual_grab_standard_tv(
         _series,
         _season_number,
         %Release{resolution_evidence: :conflicting_standard_numbering}
       ),
       do: {:error, :conflicting_standard_numbering}

  defp manual_grab_standard_tv(%Series{id: series_id}, season_number, %Release{} = release) do
    candidates = EpisodeSearch.manual_search_episodes(series_id, season_number)

    case standard_manual_episode_ids(release, season_number, candidates) do
      {:ok, []} -> {:error, :nothing_wanted}
      {:ok, ids} -> grab_and_create_grab(release, ids)
      :error -> {:error, :conflicting_standard_numbering}
    end
  end

  defp standard_manual_episode_ids(
         %Release{resolved_episode_ids: ids},
         _season_number,
         candidates
       )
       when is_list(ids) and ids != [] do
    candidate_ids = MapSet.new(candidates, & &1.id)

    if Enum.uniq(ids) == ids and MapSet.subset?(MapSet.new(ids), candidate_ids),
      do: {:ok, ids},
      else: :error
  end

  # An alternate-season release that reached here UNRESOLVED (no frozen episode ids — an unmapped
  # value in a bridged season, an alt season past the cap, or a mapping outside the current
  # candidates) must never fall through to the native intersection below: grabbing "S02E11" while
  # browsing native season 1 would reserve native S01E11. Refuse instead (never-guess).
  defp standard_manual_episode_ids(%Release{season: release_season}, season_number, _candidates)
       when is_integer(release_season) and release_season != season_number,
       do: :error

  defp standard_manual_episode_ids(%Release{} = release, _season_number, candidates) do
    covered = cover_numbers(release, Enum.map(candidates, & &1.episode_number))
    {:ok, candidates |> Enum.filter(&(&1.episode_number in covered)) |> Enum.map(& &1.id)}
  end

  # Grabs the release (a client.add side-effect returning a download_id), then links the grab over
  # `episode_ids`. If create_grab/5 rolls back — a concurrent sweep grabbed the episodes first
  # (:no_episodes_linked, or :episode_ownership_changed for some of them) or the insert failed —
  # best-effort remove the just-added download so it isn't orphaned in the client, then surface the
  # error.
  defp grab_and_create_grab(%Release{} = release, episode_ids) do
    Download.grab_episodes(release, episode_ids, operator_initiated: true)
  end

  # A whole-season pack (episodes: nil) covers every still-wanted number; an episode list covers its
  # intersection with what's wanted. Mirrors Scorer.coverage/2.
  defp cover_numbers(%Release{episodes: nil}, wanted_numbers), do: wanted_numbers

  defp cover_numbers(%Release{episodes: eps}, wanted_numbers),
    do: Enum.filter(wanted_numbers, &(&1 in eps))

  # The fresh Anime parser context and the manual candidate set, read in one transaction.
  defp anime_manual_grab_context(series_id, season_number) do
    {:ok, result} =
      Repo.transaction(fn ->
        context = MediaProfiles.anime_series_acquisition_context(%Series{id: series_id})

        candidate_ids =
          series_id
          |> EpisodeSearch.manual_search_episodes(season_number)
          |> Enum.map(& &1.id)

        %{context: context, candidate_ids: candidate_ids}
      end)

    result
  end
end
