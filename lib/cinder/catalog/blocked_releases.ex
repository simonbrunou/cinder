defmodule Cinder.Catalog.BlockedReleases do
  @moduledoc """
  The release blocklist for movies and series: every write to `blocked_releases` but the
  retention prune (`Cinder.Accounts.Janitor`), and every read release selection makes of it. A
  blocked release is one Cinder will not grab again for that movie or series; its `reason` says
  why.

  Two kinds of write:

    * **Non-raising** (`block_release/2`, `block_series_release/3`, `block_unplaced_pack/2`):
      for the pollers' park paths, which run inside `isolate/2`, where a raise would re-fire
      every tick with nothing parked. A refused or raised insert is logged and swallowed, and
      the call returns `:ok` (mirrors `Download.best_effort_remove/2`).
    * **Strict** (`block_policy_mismatch/3`): for a caller inside a transaction whose other
      writes must not commit without the row, so it gets `{:error, changeset}` back.

  Nothing here broadcasts.
  """
  import Ecto.Query
  require Logger

  alias Cinder.Catalog.{BlockedRelease, Movie}
  alias Cinder.Repo

  # #274. A blocklist reason that bounds the UPGRADE sweep alone. Every other reason means "this
  # release is bad for this title"; this one means only "it did not beat what we already hold", so
  # it must stay invisible to the wanted-episode sweep and the manual panel — see
  # `blocked_release_titles_for_series/2`.
  @no_upgrade_reason "no_upgrade"
  @upgrade_only_reasons [@no_upgrade_reason]

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
  """
  def block_series_release(_series, nil, _reason), do: :ok

  def block_series_release(series, title, reason) do
    insert_quietly(fn ->
      %{release_title: title, reason: to_string(reason), series_id: series_id(series)}
    end)
  end

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

  @doc "Downcased-or-not release titles blocked for `movie` (the exact strings stored)."
  def blocked_release_titles(%Movie{id: movie_id}),
    do:
      Repo.all(from b in BlockedRelease, where: b.movie_id == ^movie_id, select: b.release_title)

  @doc """
  Release titles blocked for the series `series_id`.

  Upgrade-only reasons (`#{inspect(@upgrade_only_reasons)}`) are **excluded** unless the caller
  names one in `:include_reasons`. Such a row is not "this release is bad": it is the season's
  best pack, recorded only because the import arbitrated it down to nothing placed. Hiding it
  from the wanted-episode sweep or the manual panel would strand that pack for the janitor's
  whole retention window — wrong the moment an episode of the season is deleted, lost or
  re-monitored. `Cinder.Catalog.UpgradeHunter` is the only caller that should include it.
  """
  def blocked_release_titles_for_series(series_id, opts \\ []) do
    included = opts |> Keyword.get(:include_reasons, []) |> Enum.map(&to_string/1)

    Repo.all(
      from b in BlockedRelease,
        where: b.series_id == ^series_id,
        where: is_nil(b.reason) or b.reason not in ^(@upgrade_only_reasons -- included),
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
end
