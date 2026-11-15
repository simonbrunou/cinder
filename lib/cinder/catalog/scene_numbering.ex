defmodule Cinder.Catalog.SceneNumbering do
  @moduledoc """
  Operator-chosen alternate-season numbering (A6): the TMDB episode-group picker (list and
  save) and the `(from, delta)` season-offset picker (preview and save). The group's preview and
  its "scene" coordinate write are `Cinder.Catalog.SeriesIdentitySync`'s, shared with series
  creation and refresh. Every public function here is re-exported through `defdelegate` in
  `Cinder.Catalog`.
  """
  import Ecto.Query
  require Logger

  alias Cinder.Catalog.{Episode, Events, Identity, Series, SeriesIdentitySync}
  alias Cinder.Repo
  alias Cinder.Util

  @doc """
  Lists a series' TMDB episode groups, for the alternate-numbering picker.
  """
  def list_episode_groups(%Series{tmdb_id: tmdb_id}), do: tmdb().get_episode_groups(tmdb_id)

  @doc "Fetches one TMDB episode group's detail, for the alternate-numbering picker."
  def get_episode_group(group_id), do: tmdb().get_episode_group(group_id)

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
  coordinates while reporting success. The one exception is a re-save of the group that is
  already the series' persisted current group: nothing was going to change anyway, so a transient
  TMDB blip there is a logged no-op (`{:ok, series}`, existing coordinates untouched) rather than
  an error — decided from a fresh `Repo.get` of the series row, not the caller's (possibly stale)
  `series` struct, so a stale tab attempting a genuine switch-back can't be mistaken for a no-op
  once a second writer has actually moved the group on.

  `opts[:detail]` lets a caller reuse a TMDB episode-group detail it already fetched (e.g. the
  series-detail picker's own preview fetch), skipping a redundant round trip — but only when it
  was fetched for this same `group_id` (`detail.id == group_id`); otherwise it's ignored and the
  detail is fetched fresh, same as the arity-2 call.
  """
  def set_scene_numbering_group(%Series{} = series, group_id, opts \\ []) do
    group_id = Util.blank_to_nil(group_id)

    case resolve_scene_group_detail(group_id, opts) do
      {:ok, detail} ->
        series.id
        |> save_scene_numbering_group(group_id, detail)
        |> finish_series_write()

      {:error, :group_fetch_failed} ->
        same_group_resave_noop(series, group_id)
    end
  end

  # A re-save of the group that is already this series' persisted current group hitting a
  # transient TMDB blip is a harmless no-op (nothing yet needed to change); a NEW/different
  # group selection still fails loud via the fallback clause below. Decided from a fresh read of
  # the series row, not the caller's `series` struct — a stale tab's struct can still show a group
  # a second writer has since moved away from, and comparing against that stale value would
  # falsely report "no-op success" for what is actually a genuine (failed) switch-back.
  defp same_group_resave_noop(series, group_id) do
    case Repo.get(Series, series.id) do
      %Series{scene_numbering_group_id: ^group_id} ->
        Logger.warning(
          "scene numbering: series #{series.id} re-save of already-current group " <>
            "#{inspect(group_id)} failed to fetch, keeping existing coordinates (no-op)"
        )

        {:ok, series}

      _current_or_nil ->
        {:error, :group_fetch_failed}
    end
  end

  defp resolve_scene_group_detail(nil, _opts), do: {:ok, nil}

  defp resolve_scene_group_detail(group_id, opts) do
    case Keyword.get(opts, :detail) do
      %{id: ^group_id} = detail ->
        {:ok, detail}

      _stale_or_absent ->
        case SeriesIdentitySync.fetch_scene_group(group_id) do
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
             :ok <- SeriesIdentitySync.sync_scene_group(updated, previous, detail) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      nil ->
        Repo.rollback(:stale_series)
    end
  end

  @doc """
  Pure preview of the scene coordinates a `(from, delta)` season offset would generate for `series`
  (issue #156): every episode in a TMDB season `>= from` gets a scene code
  `Episode.code(season_number + delta, episode_number)`. Shares its derivation with
  `save_scene_offset_coordinates/3` (via `derive_offset/3`) so the preview can never differ from
  what Save persists. Each returned row is one derived scene season (sorted), carrying the source
  TMDB season, the episode-number range, the count, and `collisions` — derived codes that equal the
  *native* code of a different episode in the series. Collisions are the case the operator must
  consciously vet: the operator's alt numbering will win over that native episode at resolution
  (`AnimeResolver.strip_shadowed_canonical/1`), so a native-numbered release of that episode would
  be interpreted as the alt-numbered one. Saving also retires the native code of every episode the
  offset shifts (`AnimeResolver.retired_canonical?/2`, #987): a release naming that code no longer
  reads as that episode. `series` must carry its preloaded season/episode tree
  (`get_series_with_tree/1`). Returns `[]` for an invalid offset (`from < 1`, `delta == 0`,
  non-integers).
  """
  def preview_scene_offset(%Series{seasons: seasons}, from, delta)
      when is_integer(from) and is_integer(delta) and from >= 1 and delta != 0 do
    episodes = tree_episodes(seasons)
    native_owner = Map.new(episodes, &{Episode.code(&1.season_number, &1.episode_number), &1.id})

    episodes
    |> derive_offset(from, delta)
    |> Enum.group_by(fn %{episode: e} -> e.season_number + delta end)
    |> Enum.map(fn {scene_season, derived} ->
      %{
        tmdb_season: hd(derived).episode.season_number,
        scene_season: scene_season,
        count: length(derived),
        episode_range: minmax(Enum.map(derived, & &1.episode.episode_number)),
        collisions:
          for(
            %{episode: e, scene_code: code} <- derived,
            owner = Map.get(native_owner, code),
            not is_nil(owner) and owner != e.id,
            do: code
          )
      }
    end)
    |> Enum.sort_by(& &1.scene_season)
  end

  def preview_scene_offset(_series, _from, _delta), do: []

  @doc """
  Persists the `(from, delta)` season-offset scene coordinates for `series` as **vetted**
  (`:curated`) rows in the `"offset"` namespace, replacing any it previously wrote (a `:manual`
  per-episode correction in that namespace survives). `from`/`delta` both `nil` clears them.
  Broadcasts on the `"series"` topic. Returns `{:ok, series}`, `{:error, :invalid_offset}` for
  `from < 1` / `delta == 0` / mixed nil, or `{:error, reason}` on a write failure. Loads episodes
  itself. See `preview_scene_offset/3` for the derivation the operator reviews first.
  """
  def save_scene_offset_coordinates(%Series{} = series, from, delta) do
    with {:ok, coords} <- offset_coords(series, from, delta),
         {:ok, _} <-
           Identity.replace_provider_coordinates(series, "offset", "offset", "scene", coords) do
      Events.series_updated(series.id)
      {:ok, series}
    end
  end

  defp offset_coords(_series, nil, nil), do: {:ok, []}

  defp offset_coords(series, from, delta)
       when is_integer(from) and is_integer(delta) and from >= 1 and delta != 0 do
    coords =
      series
      |> offset_episodes()
      |> derive_offset(from, delta)
      |> Enum.map(fn %{episode: e, scene_code: code} ->
        %{scheme: "scene", canonical_value: code, precedence: :curated, episode_ids: [e.id]}
      end)
      |> drop_offset_collisions()

    {:ok, coords}
  end

  defp offset_coords(_series, _from, _delta), do: {:error, :invalid_offset}

  # Eligible episodes: TMDB season >= from, and the shifted season stays >= 1 (never derive S00 or a
  # negative season). Shared by preview (from the preloaded tree) and save (queried) so both derive
  # the identical set.
  defp derive_offset(episodes, from, delta) do
    for e <- episodes,
        e.season_number >= from,
        e.season_number + delta >= 1,
        do: %{episode: e, scene_code: Episode.code(e.season_number + delta, e.episode_number)}
  end

  defp tree_episodes(seasons) do
    for season <- seasons,
        episode <- season.episodes,
        do: %{
          id: episode.id,
          season_number: season.season_number,
          episode_number: episode.episode_number
        }
  end

  defp offset_episodes(%Series{id: series_id}) do
    Repo.all(
      from e in Episode,
        join: s in assoc(e, :season),
        where: s.series_id == ^series_id,
        select: %{id: e.id, season_number: s.season_number, episode_number: e.episode_number}
    )
  end

  # Defensive only: a valid offset is a bijective season shift, so derived codes are unique. If
  # duplicate (season, episode) rows ever produced a shared code, drop every colliding one rather
  # than let one silently win (and to never trip the coordinate unique index).
  defp drop_offset_collisions(coords) do
    counts = Enum.frequencies_by(coords, & &1.canonical_value)
    Enum.filter(coords, &(Map.fetch!(counts, &1.canonical_value) == 1))
  end

  defp minmax([]), do: nil
  defp minmax(numbers), do: Enum.min_max(numbers)

  # A `Repo.transaction` result whose ok value is the updated `%Series{}` broadcasts once on the
  # "series" topic and passes through; an error passes through untouched.
  # `Cinder.Catalog.MetadataRefresh.refresh_series/1` keeps its own copy, small enough to
  # duplicate rather than share.
  defp finish_series_write({:ok, updated}) do
    Events.series_updated(updated.id)
    {:ok, updated}
  end

  defp finish_series_write({:error, reason}), do: {:error, reason}

  # Resolve the impl at runtime — see `Cinder.Catalog.Discovery`'s copy for why not compile_env!.
  defp tmdb, do: Application.fetch_env!(:cinder, :tmdb)
end
