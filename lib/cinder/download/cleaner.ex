defmodule Cinder.Download.Cleaner do
  @moduledoc """
  Reaps download-client entries Cinder submitted but no longer owns — the junk a crashed,
  cancelled or aborted flow leaves wedged in the client queue with nothing left to finish it.

  Every download Cinder submits is marked with its operation key (a `cinder-<key>` tag on
  torrents, a job-name suffix on usenet), and `Client.list_managed/0` reports **only** those. A
  household's hand-added downloads are invisible to this sweep by construction, not by a filter
  that could be got wrong.

  An entry is an **orphan** when its operation key matches no `download_intents` row *and* its id
  is not the live `download_id` of a movie or a grab. Orphans are removed with their files.

  Completed torrents remain untouched by default. Operators may opt into cleanup with
  `ratio_limit` and/or `seed_time_limit_hours` in this module's runtime config. A completed entry
  is removed only after import has released every Cinder owner and the client reports that at
  least one configured limit has been reached. Missing client metrics fail closed.

  **On by default** — the shipped `config/config.exs` sets `enabled: true`. (`enabled?/0`'s own
  fallback is `false`, so an install with no config block at all stays off — fail-safe, mirroring
  `Cinder.Download.StallReaper`.)

  Lifecycle is `Cinder.Download.PollerSkeleton` (`stateful: false`): stateless, self-rescheduling,
  crash-recoverable. Interval is module config
  (`config :cinder, #{inspect(__MODULE__)}, interval: <ms>`).
  """
  import Ecto.Query

  alias Cinder.Books.BookGrab
  alias Cinder.Catalog.{Grab, Movie}
  alias Cinder.Download
  alias Cinder.Download.Intent
  alias Cinder.Repo

  @default_interval :timer.hours(1)

  use Cinder.Download.PollerSkeleton,
    log_prefix: "cleaner",
    stateful: false,
    first_interval: :timer.minutes(5)

  @doc "Whether the orphan sweep is enabled (`config :cinder, #{inspect(__MODULE__)}, enabled: true`)."
  def enabled?, do: Keyword.get(config(), :enabled, false)

  defp do_poll do
    if enabled?() do
      Enum.each(Download.available_protocols(), &isolate("#{&1} orphans", fn -> sweep(&1) end))
    end

    :ok
  end

  defp sweep(protocol) do
    with {:ok, client} <- Download.client_for(protocol),
         {:ok, entries} <- client.list_managed() do
      entries
      |> Enum.filter(&reapable?/1)
      |> unclaimed(protocol)
      |> Enum.each(&reap(client, &1))
    else
      # No client configured for this protocol — nothing to sweep.
      :error ->
        :ok

      {:error, reason} ->
        Logger.warning("cleaner could not list #{protocol} downloads: #{inspect(reason)}")
    end
  end

  # Two batched lookups rather than one query per entry: the client list is small (a household
  # queue), but a per-entry query would be a round trip each on every tick.
  defp unclaimed([], _protocol), do: []

  defp unclaimed(entries, protocol) do
    keys = claimed_keys(Enum.map(entries, & &1.operation_key))
    ids = claimed_ids(Enum.map(entries, & &1.id), protocol)

    Enum.reject(
      entries,
      &(MapSet.member?(keys, &1.operation_key) or MapSet.member?(ids, &1.id))
    )
  end

  # `operation_key` is an `Ecto.UUID.generate/0` value, unique across ALL intents regardless of
  # protocol (`unique_constraint(:operation_key)` in `Intent.changeset/2` has no protocol scope) —
  # a cross-protocol collision is a UUID collision, not a reachable case worth a query filter. So
  # unlike `claimed_ids/2` below, this lookup does not need the sweep's protocol threaded in.
  defp claimed_keys(keys) do
    MapSet.new(
      Repo.all(from i in Intent, where: i.operation_key in ^keys, select: i.operation_key)
    )
  end

  # A movie, grab, or book grab still pointing at the download owns it even with no intent row
  # left — the intent is deleted once the pipeline has taken ownership, so this is the second half
  # of "ours".
  #
  # `book_grabs` matters here for the same reason `grabs` does, and more sharply: a book intent is
  # completed at SUBMISSION time (`reconcile_book_target/1` hands ownership to the grab as soon as
  # the remote id exists), so from that moment the only thing claiming a live book download is its
  # `book_grabs` row. Omitting it made every in-flight book download an orphan the next tick, and
  # `reapable?/1` removes a `:downloading` orphan with `delete_files: true`.
  #
  # Download ids are client-local (a qBittorrent infohash, a SABnzbd `nzo_id`, an NZBGet integer)
  # with no cross-client uniqueness guarantee, so a bare `download_id in ^ids` match without the
  # sweep's own protocol would read a live download on one client as claimed by an unrelated
  # orphan on another. `grabs.download_protocol` and `book_grabs.download_protocol` are `NOT
  # NULL`; `movies.download_protocol` is nullable (added after movies already had live downloads —
  # `20260619140000_add_download_protocol_to_movies.exs`) and every other read site
  # (`Download.client_for/1`, `Download.insert_movie_cleanup!/2`) resolves a `nil` movie row as
  # `:torrent`. This matches that same convention rather than treating a nil protocol as
  # universally claimed, which would silently re-open the shielding bug for a legacy row on the
  # usenet sweep.
  defp claimed_ids(ids, protocol) do
    nil_protocol_is_torrent? = protocol == :torrent

    # A movie at :available has committed its import and needs no further source bytes — the
    # only status this releases for. Every other status (mid-download, mid-import at :downloaded,
    # :upgrading, or a held :import_failed verification park that keeps frozen ownership) keeps
    # protecting its download_id, matching ReleaseVerification's contract that a hold never
    # clears ownership.
    movie_ids =
      Repo.all(
        from m in Movie,
          where:
            m.download_id in ^ids and
              m.status != :available and
              (m.download_protocol == ^protocol or
                 (^nil_protocol_is_torrent? and is_nil(m.download_protocol))),
          select: m.download_id
      )

    grab_ids =
      Repo.all(
        from g in Grab,
          where: g.download_id in ^ids and g.download_protocol == ^protocol,
          select: g.download_id
      )

    book_ids =
      Repo.all(
        from g in BookGrab,
          where: g.download_id in ^ids and g.download_protocol == ^protocol,
          select: g.download_id
      )

    MapSet.new(movie_ids ++ grab_ids ++ book_ids)
  end

  defp reap(client, entry) do
    reason = if entry.state == :completed, do: "torrent cleanup limit reached", else: "orphaned"

    Logger.warning(
      "cleaner removing #{reason} #{entry.state} download #{entry.id} " <>
        "(operation #{entry.operation_key} has no owner)"
    )

    Download.best_effort_remove(client, entry.id)
  end

  defp reapable?(%{state: state}) when state in [:downloading, :error], do: true

  defp reapable?(%{state: :completed} = entry) do
    reached?(Map.get(entry, :ratio), ratio_limit()) or
      reached?(Map.get(entry, :seeding_time), seed_time_limit_seconds())
  end

  defp reapable?(_entry), do: false

  defp reached?(value, limit) when is_number(value) and is_number(limit), do: value >= limit
  defp reached?(_value, _limit), do: false

  defp ratio_limit, do: positive_number(Keyword.get(config(), :ratio_limit))

  defp seed_time_limit_seconds do
    case positive_number(Keyword.get(config(), :seed_time_limit_hours)) do
      hours when is_number(hours) -> hours * 3600
      nil -> nil
    end
  end

  defp positive_number(value) when is_number(value) and value > 0, do: value

  defp positive_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} when number > 0 -> number
      _ -> nil
    end
  end

  defp positive_number(_value), do: nil

  defp config, do: Application.get_env(:cinder, __MODULE__, [])
end
