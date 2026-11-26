defmodule Cinder.Catalog.BlockedReleases do
  @moduledoc """
  The release blocklist for movies and series: every write to `blocked_releases` but the
  retention prune (`Cinder.Accounts.Janitor`), and every read release selection makes of it. A
  row records a blocked release, one Cinder will not grab again for that movie or series, and its
  `reason` says why, or a park strike (below).

  A TV grab with a release title that parks without a block leaves a park strike instead: one row
  per park, under a reason that blocks nothing alone. Once a series holds three strikes for one
  release title, `blocked_release_titles_for_series/2` blocks that title, so a release that parks
  on every grab stops being grabbed (#1588). A manual episode or season Search that puts an
  episode of the series back in the search clears the series' strikes (`clear_park_strikes/1`),
  and the retention prune ages each strike out on its own. Clearing the strikes lifts no other
  block on the title.

  Two kinds of write:

    * **Non-raising** (`block_release/2`, `block_series_release/4`, `block_unplaced_pack/2`):
      for the pollers' park paths and a refused TV submission (`Cinder.Download`), which run
      inside a poller's `isolate/2`, where a raise would re-fire every tick: a park with nothing
      parked, a submission whose reservation is never dropped. A refused or raised insert is
      logged and swallowed, and the call returns `:ok` (mirrors
      `Cinder.Download.SourceRemoval.best_effort_remove/2`).
    * **Strict** (`block_policy_mismatch/3`, `record_park_strike!/2`): for a caller inside a
      transaction whose other writes must not commit without the row. The first returns
      `{:error, changeset}`; the second raises.

  Nothing here broadcasts.
  """
  import Ecto.Query
  require Logger

  alias Cinder.Catalog.{BlockedRelease, Movie}
  alias Cinder.Indexers
  alias Cinder.Repo

  # #274. A blocklist reason that bounds the UPGRADE sweep alone. Every other reason means "this
  # release is bad for this title"; this one means only "it did not beat what we already hold", so
  # it must stay invisible to the wanted-episode sweep and the manual panel — see
  # `blocked_release_titles_for_series/2`.
  @no_upgrade_reason "no_upgrade"
  @upgrade_only_reasons [@no_upgrade_reason]

  # #1588. One row per TV park that blocked nothing. A title blocks only once a series holds
  # `@park_strikes_to_block` of them, so a host fault that parks a good release once or twice
  # leaves it grabbable.
  @park_strike_reason "park_strike"
  @park_strikes_to_block 3

  # #1673, #1622 point 3. The refusals about a release's content, which hold whichever source
  # served it, so a scoped row of one of them also blocks its title under the linked indexer of
  # the other source. `unsupported_download_url` is about the link one source serves, so it stays
  # in its own. `bad_download_file` is #1658's reason; a reason no row holds matches nothing.
  @crossing_reasons ["add_rejected", "bad_torrent", "bad_download_file"]
  @prowlarr_source "prowlarr"
  @native_source "native"

  @doc """
  Records `movie`'s current `release_title` as blocked for that movie, so release selection
  skips it on the next search. A nil `release_title` (e.g. a pre-grab park) is a no-op.
  Non-raising; always `:ok`.
  """
  def block_release(%Movie{release_title: nil}, _reason), do: :ok

  def block_release(%Movie{release_title: title, id: movie_id}, reason),
    do:
      insert_quietly(fn ->
        %{release_title: title, reason: to_string(reason), movie_id: movie_id}
      end)

  @doc """
  `block_release/2`, then confirms the row is readable back under the movie's exact
  `release_title`: `:ok` if it landed, `:error` if it did not. For the one caller that cannot
  proceed without the row — `Cinder.Catalog.MovieLifecycle.record_failure/2`'s re-queue, where the
  blocklist is the only bound on a re-queue loop, so a missing row means re-grabbing the same
  failed release forever.
  Everyone else calls `block_release/2` and ignores the outcome (deliberately non-raising, see
  above). A nil `release_title` is `:error` — nothing to block means nothing to bound the loop.
  """
  def block_release_and_confirm(%Movie{release_title: title} = movie, reason) do
    block_release(movie, reason)

    if not is_nil(title) and title in blocked_release_titles(movie), do: :ok, else: :error
  end

  @doc """
  Records `title` as blocked for a series. `series` is the series id, or a zero-arity function
  returning it when finding it is itself a query: the function runs inside the non-raising
  guard, so a failed lookup is logged like a failed insert. A nil `title` is a no-op.
  Non-raising; always `:ok`.

  `indexer`, a `{source, indexer_id}` pair with a string source and an integer id, scopes the row
  to one indexer (#1515, #1645): it then blocks `title` only in a search result from that source
  whose indexer id is the row's or nil (`blocked_release_titles_for_series/2`). Only a refused TV
  submission (`Cinder.Download`) passes one; nil, the default, blocks `title` from every indexer.
  The row records both or neither: with a non-nil `title`, any other `indexer` is logged and
  records nothing.
  """
  def block_series_release(series, title, reason, indexer \\ nil)

  def block_series_release(_series, nil, _reason, _indexer), do: :ok

  def block_series_release(series, title, reason, indexer) do
    case indexer_columns(indexer) do
      {:ok, columns} ->
        insert_quietly(fn ->
          Map.merge(columns, %{
            release_title: title,
            reason: to_string(reason),
            series_id: series_id(series)
          })
        end)

      :error ->
        Logger.warning(
          "block_series_release recorded nothing for #{inspect(title)}: " <>
            "indexer #{inspect(indexer)} is not nil or {source, indexer_id}"
        )

        :ok
    end
  end

  defp indexer_columns(nil), do: {:ok, %{indexer_source: nil, indexer_id: nil}}

  defp indexer_columns({source, id}) when is_binary(source) and is_integer(id),
    do: {:ok, %{indexer_source: source, indexer_id: id}}

  defp indexer_columns(_indexer), do: :error

  @doc """
  Records a season pack whose import placed nothing (every episode an arbitrated keep, #250) under
  the upgrade-only reason: it bounds the upgrade sweep that grabbed it and stays grabbable
  everywhere else (`blocked_release_titles_for_series/2`). Non-raising; always `:ok`.
  """
  def block_unplaced_pack(series_id, title),
    do: block_series_release(series_id, title, @no_upgrade_reason)

  @doc """
  Records a confirmed release whose files broke the release's policy snapshot (`evidence`), for
  `[movie: id]` or `[series: id]`, inside the caller's transaction: `{:ok, row}` or
  `{:error, changeset}`.
  """
  def block_policy_mismatch(scope, title, evidence) do
    %BlockedRelease{}
    |> BlockedRelease.changeset(
      Map.merge(scope_attrs(scope), %{
        release_title: title,
        reason: inspect({:release_policy_mismatch, evidence})
      })
    )
    |> Repo.insert()
  end

  @doc """
  Deletes the `:stalled`-reason blocklist rows for a movie or series so a manual re-search can give
  the reaped release a fresh chance. Scoped to `[movie: id]` or `[series: id]`; only `"stalled"`
  rows are removed, so deterministic blocks (wrong-language, bad-torrent, …) still persist. A nil id
  is a no-op. The series scope clears the whole series' `:stalled` rows (the table is series-keyed).
  """
  def clear_stalled_blocklist(movie: id) when is_integer(id) do
    Repo.delete_all(from b in BlockedRelease, where: b.movie_id == ^id and b.reason == "stalled")

    :ok
  end

  def clear_stalled_blocklist(series: id) when is_integer(id) do
    Repo.delete_all(from b in BlockedRelease, where: b.series_id == ^id and b.reason == "stalled")

    :ok
  end

  def clear_stalled_blocklist(_scope), do: :ok

  @doc """
  Records one park strike for `title` in the series `series_id`, inside the caller's park
  transaction, so only a park that commits counts. A nil `series_id` (a grab with no linked
  episode) or a nil or empty `title` records nothing. Raises when the insert fails, which rolls
  the park back with it.
  """
  def record_park_strike!(series_id, title)
      when is_nil(series_id) or is_nil(title) or title == "",
      do: :ok

  def record_park_strike!(series_id, title) do
    %BlockedRelease{}
    |> BlockedRelease.changeset(%{
      release_title: title,
      reason: @park_strike_reason,
      series_id: series_id
    })
    |> Repo.insert!()

    :ok
  end

  @doc """
  Deletes every park strike of the series `series_id`, so each of its titles takes three more
  parks before its strikes block it. A block of another reason on the title stays. The manual
  episode and season Searches call it next to `clear_stalled_blocklist/1`, when they put an
  episode of the series back in the search.
  """
  def clear_park_strikes(series_id) when is_integer(series_id) do
    Repo.delete_all(
      from b in BlockedRelease,
        where: b.series_id == ^series_id and b.reason == @park_strike_reason
    )

    :ok
  end

  @doc "Downcased-or-not release titles blocked for `movie` (the exact strings stored)."
  def blocked_release_titles(%Movie{id: movie_id}),
    do:
      Repo.all(from b in BlockedRelease, where: b.movie_id == ^movie_id, select: b.release_title)

  @doc """
  Release titles blocked for the series `series_id`, the `:release_blocklist` that
  `Cinder.Acquisition.Scorer` reads. A row with no indexer id gives its title as a string, which
  blocks that title from every indexer. A row with one gives `{title, {source, indexer_id}}`,
  which blocks that title only in a result from that source whose indexer id is the row's or nil
  (#1515, #1645). A scoped row of a content refusal (`#{inspect(@crossing_reasons)}`) also gives
  `{title, {source, id}}` for its indexer's linked pair in the other source, read through
  `Cinder.Indexers.prowlarr_links/0` (#1673): Prowlarr indexer P pairs with the configured
  indexer whose `prowlarr_indexer_id` is P, and that `"native"` indexer pairs with P. A row whose
  indexer has no link, or of another reason, gives only its own entry.

  Upgrade-only reasons (`#{inspect(@upgrade_only_reasons)}`) are **excluded** unless the caller
  names one in `:include_reasons`. Such a row is not "this release is bad": it is the season's
  best pack, recorded only because the import arbitrated it down to nothing placed. Hiding it
  from the wanted-episode sweep or the manual panel would strand that pack for the janitor's
  whole retention window — wrong the moment an episode of the season is deleted, lost or
  re-monitored. `Cinder.Catalog.UpgradeHunter` is the only caller that should include it.

  A park strike row never gives its title alone, whatever `:include_reasons` names. A title that
  holds three or more strikes in the series is given as a plain title, which blocks it from every
  indexer (#1588).
  """
  def blocked_release_titles_for_series(series_id, opts \\ []) do
    included = opts |> Keyword.get(:include_reasons, []) |> Enum.map(&to_string/1)
    hidden = [@park_strike_reason | @upgrade_only_reasons -- included]

    rows =
      Repo.all(
        from b in BlockedRelease,
          where: b.series_id == ^series_id,
          where: is_nil(b.reason) or b.reason not in ^hidden,
          select: {b.release_title, b.indexer_source, b.indexer_id, b.reason}
      )

    blocked =
      Enum.map(rows, fn
        {title, _source, nil, _reason} -> title
        {title, source, id, _reason} -> {title, {source, id}}
      end)

    pairs = rows |> linked_pair_entries() |> Enum.reject(&(&1 in blocked)) |> Enum.uniq()
    blocked = blocked ++ pairs

    blocked ++ (struck_out_titles(series_id) -- blocked)
  end

  # The entry each crossing scoped row adds under its indexer's linked pair of the other source
  # (#1673): Prowlarr indexer P and the configured indexer whose `prowlarr_indexer_id` is P. A row
  # whose indexer has no link adds none. The links are read only when a row can cross.
  defp linked_pair_entries(rows) do
    crossing =
      for {title, source, id, reason} <- rows,
          reason in @crossing_reasons and not is_nil(id),
          do: {title, source, id}

    if crossing == [] do
      []
    else
      links = Indexers.prowlarr_links()
      native_of = Map.new(links, fn {native, prowlarr} -> {prowlarr, native} end)
      prowlarr_of = Map.new(links)

      for {title, source, id} <- crossing,
          other = pair(source, id, native_of, prowlarr_of),
          other != nil,
          do: {title, other}
    end
  end

  defp pair(@prowlarr_source, id, native_of, _prowlarr_of),
    do: if(native = native_of[id], do: {@native_source, native})

  defp pair(@native_source, id, _native_of, prowlarr_of),
    do: if(prowlarr = prowlarr_of[id], do: {@prowlarr_source, prowlarr})

  defp pair(_source, _id, _native_of, _prowlarr_of), do: nil

  defp struck_out_titles(series_id) do
    Repo.all(
      from b in BlockedRelease,
        where: b.series_id == ^series_id and b.reason == @park_strike_reason,
        group_by: b.release_title,
        having: count(b.id) >= @park_strikes_to_block,
        select: b.release_title
    )
  end

  defp scope_attrs(movie: id), do: %{movie_id: id}
  defp scope_attrs(series: id), do: %{series_id: id}

  defp series_id(resolve) when is_function(resolve, 0), do: resolve.()
  defp series_id(series_id), do: series_id

  # Non-raising on every path: the attrs thunk runs inside the try, so a changeset/constraint
  # `{:error, _}` is logged-and-swallowed AND a raised/exited DB failure (in the insert OR a lazy
  # series-id query) is caught — the TV caller blocks BEFORE `park_grab` deletes the grab, so a
  # raise here would stop the park and hot-loop the grab every tick.
  defp insert_quietly(build_attrs) do
    attrs = build_attrs.()

    # Set on the struct, not cast: only `block_series_release/4` passes them, from a stored intent.
    {indexer, cast_attrs} = Map.split(attrs, [:indexer_source, :indexer_id])

    case struct(BlockedRelease, indexer)
         |> BlockedRelease.changeset(cast_attrs)
         |> Repo.insert() do
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
end
