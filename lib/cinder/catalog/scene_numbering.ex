defmodule Cinder.Catalog.SceneNumbering do
  @moduledoc """
  Operator-chosen alternate-season numbering (A6): the TMDB episode-group picker
  (list/preview/save), the `(from, delta)` season-offset picker, and the "scene"
  scheme coordinate sync both drive. Carved out of `Cinder.Catalog` as plain code
  motion — every public function here is re-exported unchanged via `defdelegate`
  in `Cinder.Catalog`.
  """
  import Ecto.Query
  require Logger

  alias Cinder.Catalog.{Episode, Identity, Series, SeriesCatalog}
  alias Cinder.Repo
  alias Cinder.Util

  @doc """
  Lists a series' TMDB episode groups, for the alternate-numbering picker.
  """
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
  season number, showing both sides of the mapping — the full sorted `alt_numbers` list Save
  will write as scene coordinates (a caller renders it as a single code, a contiguous range, or a
  gap-safe listing, so a non-contiguous season is never shown as a fake smooth range) and the
  canonical episode range it resolves to (`canonical_range`).
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
        alt_numbers: matched |> Enum.map(& &1.episode_number) |> Enum.sort(),
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
      {episode.tmdb_episode_id, %{episode_number: episode.episode_number}}
    end
  end

  defp minmax([]), do: nil
  defp minmax(numbers), do: Enum.min_max(numbers)

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
             :ok <-
               sync_scene_coordinates(updated, detail, fn ->
                 SeriesCatalog.episode_identity_lookup(updated.id)
               end) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      nil ->
        Repo.rollback(:stale_series)
    end
  end

  defp clear_previous_scene_namespace(_series, previous, group_id)
       when previous in [nil] or previous == group_id,
       do: :ok

  defp clear_previous_scene_namespace(series, previous, _group_id) do
    case Identity.replace_provider_coordinates(series, "tmdb", previous, "scene", []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
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
  be interpreted as the alt-numbered one. `series` must carry its preloaded season/episode tree
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
  Persists the `(from, delta)` season-offset scene coordinates for `series` as **operator-reviewed**
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
      Cinder.Catalog.broadcast_series(series.id)
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

  # `identity.scene_group_detail` was fetched for `identity.scene_group_fetched_for` — read
  # before this refresh's transaction opened (TMDB is HTTP, never called inside a transaction).
  # `series` here is the transaction's own fresh re-read, so if a racing save changed the group in
  # between, the two ids differ: the detail belongs to a namespace `series` no longer points at,
  # and syncing it now would write the OLD group's entries under the NEW (racing save's)
  # namespace. Skip and keep whatever the racing save already wrote — never guess.
  #
  # Called from `Cinder.Catalog.SeriesCatalog.sync_series_identity/3` (both the create and the
  # refresh path share that one call site).
  @doc false
  def sync_scene_coordinates_if_current(series, identity, episode_lookup) do
    if series.scene_numbering_group_id == identity.scene_group_fetched_for do
      sync_scene_coordinates(series, identity.scene_group_detail, fn -> episode_lookup end)
    else
      Logger.info(
        "scene numbering: series #{series.id} group changed from " <>
          "#{inspect(identity.scene_group_fetched_for)} to " <>
          "#{inspect(series.scene_numbering_group_id)} mid-refresh, skipping scene sync"
      )

      :ok
    end
  end

  # Mirrors sync_absolute_coordinates/3's shape, but is a distinct writer: the operator picks
  # one specific group (`series.scene_numbering_group_id`), not "every type-2 group TMDB has."
  # `detail` is the already-fetched TMDB episode-group detail — fetched by the caller before
  # any transaction opens (`fetch_scene_group_detail/1`, threaded through
  # `set_scene_numbering_group/3` and `Cinder.Catalog.SeriesCatalog.fetch_series_identity/2`),
  # never inside one: TMDB is a live HTTP call, and running it under an open SQLite write
  # transaction risks a concurrent writer tripping the busy_timeout. `nil` means "not configured"
  # or "the fetch failed" — a failed fetch (already logged by the caller) keeps whatever scene
  # rows are already synced, never strips them. `episode_lookup_fun` is a zero-arg thunk, not the
  # lookup itself — the two nil short-circuits above mean the group is unconfigured or the fetch
  # already failed, so the (join-backed) `episode_identity_lookup/1` query must never run in
  # either case; it's only forced in the one clause that actually persists coordinates.
  defp sync_scene_coordinates(
         %Series{scene_numbering_group_id: nil},
         _detail,
         _episode_lookup_fun
       ),
       do: :ok

  defp sync_scene_coordinates(%Series{}, nil, _episode_lookup_fun), do: :ok

  defp sync_scene_coordinates(
         %Series{scene_numbering_group_id: group_id} = series,
         detail,
         episode_lookup_fun
       ) do
    coordinates = scene_coordinate_attrs(series, detail, episode_lookup_fun.())

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
      %{matched: nil, ambiguous: :duplicate_tmdb_episode_id, tmdb_episode_id: tmdb_episode_id} ->
        Logger.warning(
          "scene numbering: series #{series.id} group #{group.id} entry " <>
            "tmdb_episode_id=#{tmdb_episode_id} is claimed by more than one subgroup, " <>
            "dropping rather than guessing"
        )

        []

      %{
        matched: nil,
        ambiguous: :season_episode_collision,
        tmdb_episode_id: tmdb_episode_id,
        season_number: season_number,
        episode_number: episode_number
      } ->
        Logger.warning(
          "scene numbering: series #{series.id} group #{group.id} entry " <>
            "tmdb_episode_id=#{tmdb_episode_id} collides with another entry deriving the same " <>
            "#{Episode.code(season_number, episode_number)}, dropping both rather than guessing"
        )

        []

      %{matched: nil, tmdb_episode_id: tmdb_episode_id} ->
        Logger.warning(
          "scene numbering: series #{series.id} group #{group.id} entry " <>
            "tmdb_episode_id=#{tmdb_episode_id} matches no episode row, skipping"
        )

        []

      %{
        matched: matched,
        group_name: group_name,
        season_number: season_number,
        episode_number: episode_number
      } ->
        [
          %{
            scheme: "scene",
            canonical_value: Episode.code(season_number, episode_number),
            scope_title: group_name,
            precedence: :inferred,
            episode_ids: [matched]
          }
        ]
    end)
  end

  # The per-entry derivation shared by scene_coordinate_attrs/3 (persists) and
  # preview_scene_mapping/2 (display-only), so the picker's preview can never drift from what
  # Save actually writes. `matched` is opaque here — this function never reads its internals,
  # only its truthiness and identity — so each caller's `episode_lookup` can (and does) carry a
  # different shape for it: the write path's `episode_identity_lookup/1` maps
  # tmdb_episode_id => episode_id directly (a bare id — see its own doc for why), while the
  # preview path's `episode_lookup_from_tree/1` maps tmdb_episode_id => %{episode_number:}
  # (`preview_scene_mapping/2`'s `canonical_range` is the only reader of `matched`, and it only
  # needs the episode number). Each caller only ever destructures the shape it itself supplied
  # (`scene_coordinate_attrs/3`'s `episode_ids: [matched]` vs. `preview_scene_mapping/2`'s
  # `&1.matched.episode_number`), so the two lookups legitimately diverge rather than share one
  # shape.
  #
  # Two kinds of ambiguity get the same never-guess treatment — drop every entry involved, never
  # pick one — and both fall into the unmatched/skipped side on both the write path and the
  # preview (`ambiguous` records which, only consumed for the sync path's distinct log line):
  #   - `:duplicate_tmdb_episode_id` — a Story Arc-shaped group (type 5) can legitimately place
  #     the same episode in two subgroups: two entries sharing one tmdb_episode_id, with two
  #     different derived season/episode numbers.
  #   - `:season_episode_collision` — the mirror case: two DIFFERENT tmdb_episode_ids deriving
  #     the identical (season_number, episode_number) pair (e.g. a name-parsed "Season 1"
  #     subgroup and an order-fallback subgroup both landing on season 1, with overlapping entry
  #     orders). Left undetected, this would persist two scene coordinates sharing one
  #     canonical_value under one namespace, with no way to tell which is right.
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
          ambiguous: nil
        }
      end)

    duplicated_ids =
      mapped
      |> Enum.frequencies_by(& &1.tmdb_episode_id)
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> MapSet.new(fn {id, _count} -> id end)

    # Only entries that actually matched a real Cinder episode, and aren't already doomed by the
    # duplicate-id rule above, can genuinely collide — an unmatched entry persists nothing anyway
    # (it already falls into the plain "matches no episode row" skip below), and a duplicate-id
    # entry is dropped regardless of what it derives, so neither must poison a legitimately
    # matched, non-duplicate sibling merely by sharing its derived (season, episode) key.
    colliding_keys =
      mapped
      |> Enum.filter(&(&1.matched && not MapSet.member?(duplicated_ids, &1.tmdb_episode_id)))
      |> Enum.group_by(&{&1.season_number, &1.episode_number}, & &1.tmdb_episode_id)
      |> Enum.filter(fn {_key, ids} -> ids |> Enum.uniq() |> length() > 1 end)
      |> MapSet.new(fn {key, _ids} -> key end)

    Enum.map(mapped, fn entry ->
      cond do
        MapSet.member?(duplicated_ids, entry.tmdb_episode_id) ->
          %{entry | matched: nil, ambiguous: :duplicate_tmdb_episode_id}

        entry.matched &&
            MapSet.member?(colliding_keys, {entry.season_number, entry.episode_number}) ->
          %{entry | matched: nil, ambiguous: :season_episode_collision}

        true ->
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

  # Shared by `set_scene_numbering_group/3` above and
  # `Cinder.Catalog.SeriesRefresh.refresh_series/1`: a `Repo.transaction` result whose ok value is
  # the updated `%Series{}` broadcasts once on the "series" topic and passes through; an error
  # passes through untouched. Small enough to duplicate rather than share (see the module notes).
  defp finish_series_write({:ok, updated}) do
    Cinder.Catalog.broadcast_series(updated.id)
    {:ok, updated}
  end

  defp finish_series_write({:error, reason}), do: {:error, reason}

  # The chosen scene group is sometimes also a type-2 Absolute group
  # `Cinder.Catalog.SeriesCatalog.fetch_absolute_groups/1` fetches in full — both call sites hit
  # the identical `get_episode_group` endpoint for the same id. `SeriesCatalog.scene_group_detail/2`
  # reuses that already-fetched detail when it can, falling back to this fetch otherwise.
  @doc false
  def fetch_scene_group_detail(nil), do: nil

  def fetch_scene_group_detail(group_id) do
    case tmdb().get_episode_group(group_id) do
      {:ok, detail} ->
        detail

      {:error, reason} ->
        Logger.warning("scene numbering: group #{group_id} fetch failed: #{inspect(reason)}")
        nil
    end
  end

  # Resolve the impl at runtime — see `Cinder.Catalog.Discovery`'s copy for why not compile_env!.
  defp tmdb, do: Application.fetch_env!(:cinder, :tmdb)
end
