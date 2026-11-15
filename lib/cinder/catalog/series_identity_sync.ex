defmodule Cinder.Catalog.SeriesIdentitySync do
  @moduledoc """
  A series' TMDB identity sync, shared by series creation (`Cinder.Catalog.SeriesCatalog`),
  the periodic refresh (`Cinder.Catalog.MetadataRefresh.refresh_series/1`) and the scene-numbering
  save (`Cinder.Catalog.SceneNumbering.set_scene_numbering_group/3`).

  Two halves. `fetch/3` and `fetch_scene_group/1` call TMDB and run before the caller's
  transaction opens: TMDB is a live HTTP call, and running it under an open SQLite write
  transaction risks a concurrent writer tripping the busy_timeout. `sync/2` and
  `sync_scene_group/3` write inside the caller's transaction and call no TMDB endpoint. They
  write through `Cinder.Catalog.Identity`: the series' TMDB aliases, its absolute coordinates
  (every type-2 TMDB episode group), its scene coordinates (the operator's chosen group) and its
  episodes' TMDB classifications. The season and episode rows themselves stay the callers'
  writes.

  `preview_scene_mapping/2` shows the operator what `sync_scene_group/3` would write, from the
  same private derivation, so the picker's preview never drifts from the save.

  This module calls none of its callers.
  """
  import Ecto.Query
  require Logger

  alias Cinder.Catalog.{Episode, EpisodeCoordinate, Identity, Series}
  alias Cinder.Catalog.SeriesIdentitySync.Fetched
  alias Cinder.Locales
  alias Cinder.Repo

  @doc """
  Fetches what `sync/2` and the caller's own tree write need, before any transaction opens: each
  season's episodes in the canonical locale (`season_stubs` are the `info.seasons` of
  `get_series/1`), their titles in every other locale as `:localizations`, the series' TMDB
  aliases, its type-2 (absolute) episode groups, and the detail of `scene_numbering_group_id`
  (`nil` for a brand-new series or one with no alternate numbering).

  Returns `{:ok, %Cinder.Catalog.SeriesIdentitySync.Fetched{}}`. A failed season fetch, alias
  fetch or absolute-group fetch returns `{:error, reason}` and fetches nothing further, so a
  partial tree is never persisted. A failed localization fetch is logged and leaves that locale
  out. A failed scene-group fetch is logged and leaves `scene_group_detail` `nil`, which keeps
  whatever scene rows are already synced.
  """
  def fetch(tmdb_id, season_stubs, scene_numbering_group_id) do
    with {:ok, seasons} <- fetch_seasons(tmdb_id, season_stubs, Locales.canonical()),
         seasons = put_episode_localizations(tmdb_id, seasons),
         {:ok, identity} <- fetch_identity(tmdb_id, scene_numbering_group_id) do
      {:ok, %Fetched{seasons: seasons, identity: identity}}
    end
  end

  # Fetch each season's episodes, short-circuiting on the first TMDB error so a
  # partial tree is never persisted.
  defp fetch_seasons(tmdb_id, season_stubs, locale) do
    result =
      Enum.reduce_while(season_stubs, {:ok, []}, fn %{season_number: n}, {:ok, acc} ->
        case tmdb().get_season(tmdb_id, n, locale) do
          {:ok, season} -> {:cont, {:ok, [season | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    with {:ok, seasons} <- result, do: {:ok, Enum.reverse(seasons)}
  end

  defp put_episode_localizations(tmdb_id, seasons) do
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

  # `scene_numbering_group_id` is the series' operator-chosen scene group, or `nil`. Its detail is
  # fetched here, alongside the rest of the identity data, so every TMDB call happens before the
  # caller's transaction opens. `scene_group_fetched_for` records which group id the detail
  # belongs to, so the refresh transaction can tell whether a racing save changed the group in
  # between (`sync_scene_coordinates_if_current/3`).
  defp fetch_identity(tmdb_id, scene_numbering_group_id) do
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
      nil -> fetch_scene_group(group_id)
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

  @doc """
  Fetches one TMDB episode group's detail for the scene sync, before any transaction opens.
  Returns the detail, or `nil` for a `nil` group id, a failed fetch or a detail whose id is not
  `group_id` (both logged).
  """
  def fetch_scene_group(nil), do: nil

  def fetch_scene_group(group_id) do
    case tmdb().get_episode_group(group_id) do
      {:ok, %{id: ^group_id} = detail} ->
        detail

      {:ok, detail} ->
        Logger.warning(
          "scene numbering: group #{group_id} returned mismatched id " <>
            inspect(scene_group_detail_id(detail))
        )

        nil

      {:error, reason} ->
        Logger.warning("scene numbering: group #{group_id} fetch failed: #{inspect(reason)}")
        nil
    end
  end

  defp scene_group_detail_id(detail) when is_map(detail),
    do: Map.get(detail, :id) || Map.get(detail, "id")

  defp scene_group_detail_id(_detail), do: nil

  @doc """
  Writes what `fetch/3` returned as `fetched`, inside the caller's transaction: the series' TMDB
  aliases, its absolute coordinates, its scene coordinates and its episodes' TMDB
  classifications. Runs after the caller wrote the season and episode rows, since it matches
  TMDB episodes to them by `tmdb_episode_id`.

  `series` is the caller's fresh read inside its transaction. When its
  `scene_numbering_group_id` is no longer the group `fetch/3` fetched for, a racing save changed
  it in between: the scene sync is skipped and logged, keeping what that save wrote.

  Returns `:ok`, or the first write's `{:error, reason}` for the caller to roll back.
  """
  def sync(%Series{} = series, %Fetched{seasons: seasons, identity: identity}) do
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
         :ok <- sync_scene_coordinates_if_current(series, identity, episode_lookup),
         {:ok, _} <- sync_tmdb_classifications(seasons, episode_lookup) do
      :ok
    end
  end

  # The "this series' episodes with a non-nil tmdb_episode_id" lookup shared by
  # sync_absolute_coordinates/3, the scene sync, and sync_tmdb_classifications/2 — all run
  # back-to-back inside sync/2's one transaction, and nothing between them changes an episode's
  # tmdb_episode_id, so loading it once (only when needs_episode_lookup?/2 says at least one of
  # them needs it) and threading it down is simpler than each hand-writing the same query, and one
  # less round trip too. Returns `%{tmdb_episode_id => episode_id}` directly — none of the
  # readers ever needs more than the Cinder episode id off it, unlike the preview path's
  # `episode_lookup_from_tree/1`, which stays a `%{tmdb_episode_id => %{episode_number:}}` shape
  # instead (that preview only needs the episode number).
  defp episode_identity_lookup(series_id) do
    Repo.all(
      from e in Episode,
        join: season in assoc(e, :season),
        where: season.series_id == ^series_id and not is_nil(e.tmdb_episode_id),
        select: {e.tmdb_episode_id, e.id}
    )
    |> Map.new()
  end

  # Decides whether sync/2's shared episode_identity_lookup/1 query is worth running at all: an
  # absolute-numbering group to resolve, a scene group whose detail was fetched, or a
  # season/episode tree with any TMDB-sourced episode to classify. A series with none of the
  # three needs zero episode-lookup queries.
  defp needs_episode_lookup?(seasons, identity) do
    identity.absolute_groups != [] or
      not is_nil(identity.scene_group_detail) or
      Enum.any?(seasons, fn season -> Enum.any?(season.episodes, & &1.tmdb_episode_id) end)
  end

  defp sync_absolute_coordinates(series, absolute_groups, episode_lookup) do
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

  # `identity.scene_group_detail` was fetched for `identity.scene_group_fetched_for` — read
  # before this refresh's transaction opened (TMDB is HTTP, never called inside a transaction).
  # `series` here is the transaction's own fresh re-read, so if a racing save changed the group in
  # between, the two ids differ: the detail belongs to a namespace `series` no longer points at,
  # and syncing it now would write the OLD group's entries under the NEW (racing save's)
  # namespace. Skip and keep whatever the racing save already wrote — never guess.
  defp sync_scene_coordinates_if_current(series, identity, episode_lookup) do
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

  @doc """
  Writes the scene coordinates of `series`' current group from `detail`, inside the caller's
  transaction, for the interactive scene-numbering save. `series` is the row as the caller just
  updated it, and `previous_group_id` the group it pointed at before. Switching away from a
  previous group clears that group's non-manual scene rows first, so a stale namespace cannot
  linger once nothing points at it.

  `detail` is the group's TMDB detail, fetched before the transaction opened
  (`fetch_scene_group/1`). With no current group, or a `nil` detail, it writes no scene
  coordinates and runs no episode query. Returns `:ok` or `{:error, reason}`.
  """
  def sync_scene_group(%Series{} = series, previous_group_id, detail) do
    with :ok <-
           clear_previous_scene_namespace(
             series,
             previous_group_id,
             series.scene_numbering_group_id
           ) do
      sync_scene_coordinates(series, detail, fn -> episode_identity_lookup(series.id) end)
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

  # Mirrors sync_absolute_coordinates/3's shape, but is a distinct writer: the operator picks
  # one specific group (`series.scene_numbering_group_id`), not "every type-2 group TMDB has."
  # `detail` is the already-fetched TMDB episode-group detail — fetched before any transaction
  # opens (`fetch_scene_group/1`, through `fetch/3` or the interactive save), never inside one.
  # `nil` means "not configured" or "the fetch failed" — a failed fetch (already logged by
  # fetch_scene_group/1) keeps whatever scene rows are already synced, never strips them.
  # `episode_lookup_fun` is a zero-arg thunk, not the lookup itself — the two nil short-circuits
  # mean the group is unconfigured or the fetch already failed, so the (join-backed)
  # `episode_identity_lookup/1` query must never run in either case; it's only forced in the one
  # clause that actually persists coordinates.
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

  @doc """
  Pure preview of the derived season/episode split for an already-fetched episode-group
  detail (no persistence, no further TMDB call) — shares its per-entry derivation with
  `sync_scene_group/3` (what Save actually persists) via `derive_scene_entries/2`, so
  the picker's preview can never drift from what Save writes. `series` must carry its
  preloaded season/episode tree (`SeriesCatalog.get_series_with_tree/1`); entries are matched to
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
  # tmdb_episode_id => episode_id directly (a bare id — see its own comment for why), while the
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

  # Resolve the impl at runtime — see `Cinder.Catalog.Discovery`'s copy for why not compile_env!.
  defp tmdb, do: Application.fetch_env!(:cinder, :tmdb)
end
