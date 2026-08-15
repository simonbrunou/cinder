defmodule Cinder.Requests.WatchlistSync do
  @moduledoc """
  Turns each opted-in user's Plex watchlist into that user's own requests, on a ~15 minute tick.

  Opt-in is **per user** (`users.plex_watchlist_sync`, off by default, toggled by the account's
  own owner in `/users/settings`) — there is deliberately no household-wide switch that would
  make an admin able to read everyone's watchlist.

  Every new entry goes through `Cinder.Requests.create_request/2` **as that user**, so the
  approval gate, the per-user quota and the audit trail all apply exactly as they do to the same
  user clicking Add: a watchlist entry can never create a `:requested` movie that a manual
  request from that user couldn't. Nothing here writes a movie row or a movie status; the Catalog
  choke-points are reached only through `Cinder.Requests`.

  A movie becomes one movie request. A show is expanded through TMDB into every currently known
  numbered season and becomes one request per season; Season 0 stays manual because a show-level
  Plex watchlist entry says nothing about specials. This is deliberately a snapshot, not a
  forever-subscription: a season TMDB adds after the show was first synced is picked up because
  markers are per season, but removing the show from Plex still does nothing.

  Dedupe is a per-user `synced_watchlist_entries` marker (this module owns that table), and the
  marker set alone decides what is skipped. An entry the user had already requested by hand is
  *adopted* — marked, not re-requested — so every entry ends its first tick marked either way.
  A request row can't carry this itself: `Catalog.delete_movie/3` reaps the title's `:approved`
  request in the same transaction, so a deleted-but-still-watchlisted movie would look new to the
  next tick and be silently re-requested (and, for an admin or under `auto_approve_all`,
  re-downloaded). The marker outlives that reap, so a deletion sticks — by either route.
  Removing a title from the watchlist does nothing at all: no un-requesting, no deletion.

  A token plex.tv rejects (expired or revoked) switches sync off for that ONE user and clears the
  dead token, so a tick neither wedges nor re-fails forever, and every other user's sync is
  unaffected. Transient failures just return `{:error, _}` and are retried next tick — nothing in
  a unit raises, which at a 15 minute interval would otherwise be a slow error hot loop.

  Lifecycle is `Cinder.Download.PollerSkeleton` (`stateful: false`). The interval is module
  config: `config :cinder, #{inspect(__MODULE__)}, interval: <ms>`.
  """
  import Ecto.Query

  alias Cinder.Accounts
  alias Cinder.Accounts.PlexAuth
  alias Cinder.Accounts.User
  alias Cinder.Catalog
  alias Cinder.Repo
  alias Cinder.Requests
  alias Cinder.Requests.SyncedWatchlistEntry

  @default_interval :timer.minutes(15)
  use Cinder.Download.PollerSkeleton, log_prefix: "watchlist sync", stateful: false

  @doc """
  The caller's OWN watchlist sync markers, projected to JSON-ready maps for a GDPR Art.15/20
  data export. Own data only, scoped by user id — these record which titles this user had on
  their Plex watchlist, so they belong in the export beside their requests.
  """
  def export_for_user(%User{id: id}) do
    Repo.all(
      from e in SyncedWatchlistEntry,
        where: e.user_id == ^id,
        order_by: [asc: e.target_type, asc: e.tmdb_id, asc: e.season_number],
        select: %{
          target_type: e.target_type,
          tmdb_id: e.tmdb_id,
          season_number: e.season_number,
          synced_at: e.inserted_at
        }
    )
    |> Enum.map(fn entry ->
      entry
      |> Map.update!(:synced_at, &NaiveDateTime.to_iso8601/1)
      |> Map.update!(:season_number, &if(&1 == 0, do: nil, else: &1))
    end)
  end

  defp do_poll do
    for user <- Accounts.list_plex_watchlist_users() do
      isolate("user #{user.id}", fn -> sync_user(user) end)
    end

    :ok
  end

  defp sync_user(user) do
    case Accounts.plex_token(user) do
      nil -> disable(user, "its stored Plex token could not be decrypted")
      token -> fetch(user, token)
    end
  end

  defp fetch(user, token) do
    case PlexAuth.impl().watchlist(token) do
      {:ok, entries} ->
        request_new(user, entries)

      {:error, :unauthorized} ->
        disable(user, "plex.tv rejected its stored Plex token")

      {:error, reason} ->
        Logger.warning("watchlist sync: user #{user.id} lookup failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Never names the token, only the user it belonged to.
  defp disable(user, why) do
    Logger.warning("watchlist sync: disabled for user #{user.id} because #{why}")
    Accounts.disable_plex_watchlist_sync(user)
  end

  # The marker set alone decides what is skipped, so every entry ends a tick marked — including
  # one this user had already requested by hand, which the sweep adopts rather than re-requesting.
  # Marking only what the sweep itself created would leave manually-requested titles with no
  # durable record, and `delete_movie/3`'s reap of the request row would resurrect them.
  defp request_new(user, entries) do
    marked = synced_keys(user)
    requested = requested_keys(user)

    for entry <- Enum.flat_map(entries, &expand_entry/1),
        key = entry_key(entry),
        not MapSet.member?(marked, key) do
      if MapSet.member?(requested, key),
        do: mark_synced(user, key),
        else: request_one(user, entry)
    end

    :ok
  end

  # The movie requests this user already has by any route, so a title they asked for manually
  # isn't asked for a second time.
  defp requested_keys(user) do
    user
    |> Requests.list_for_user()
    |> Enum.filter(&(&1.target_type in ["movie", "season"]))
    |> MapSet.new(&request_key/1)
  end

  defp synced_keys(user) do
    from(e in SyncedWatchlistEntry,
      where: e.user_id == ^user.id,
      select: {e.target_type, e.tmdb_id, e.season_number}
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp expand_entry(%{type: "movie"} = entry),
    do: [Map.merge(entry, %{target_type: "movie", season_number: 0})]

  defp expand_entry(%{type: "show", tmdb_id: tmdb_id} = entry) do
    case Catalog.tmdb_series(tmdb_id) do
      {:ok, info} ->
        for %{season_number: number} <- info.seasons,
            is_integer(number) and number > 0,
            do:
              Map.merge(entry, %{
                target_type: "season",
                season_number: number,
                title: info.title,
                year: info.year
              })

      {:error, reason} ->
        Logger.info("watchlist sync: could not expand show tmdb #{tmdb_id}: #{inspect(reason)}")

        []
    end
  end

  defp expand_entry(_entry), do: []

  defp entry_key(entry), do: {entry.target_type, entry.tmdb_id, entry.season_number}
  defp request_key(%{target_type: "movie", target_id: id}), do: {"movie", id, 0}

  defp request_key(%{target_type: "season", target_id: id, season_number: number}),
    do: {"season", id, number}

  # Idempotent by the unique index: two ticks racing the same entry leave one marker. A marker
  # that fails to write only costs a retry next tick. `Repo.insert` can still RAISE rather than
  # return `{:error, _}` (a busy DB or an FK violation skips `to_constraints`); `isolate/2` catches
  # that and the remaining entries for this user retry on the next tick.
  defp mark_synced(user, {target_type, tmdb_id, season_number}) do
    %SyncedWatchlistEntry{}
    |> SyncedWatchlistEntry.changeset(%{
      user_id: user.id,
      target_type: target_type,
      tmdb_id: tmdb_id,
      season_number: season_number
    })
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:user_id, :target_type, :tmdb_id, :season_number]
    )
    |> case do
      {:ok, _entry} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "watchlist sync: user #{user.id} #{target_type} tmdb #{tmdb_id} " <>
            "season #{season_number} requested but not marked: " <>
            inspect(reason)
        )
    end
  end

  defp request_one(user, entry) do
    attrs = %{
      target_type: entry.target_type,
      target_id: entry.tmdb_id,
      title: entry.title,
      year: entry.year
    }

    attrs =
      if entry.target_type == "season",
        do: Map.put(attrs, :season_number, entry.season_number),
        else: attrs

    case Requests.create_request(user, attrs) do
      {:ok, _request} ->
        mark_synced(user, entry_key(entry))

      # Quota reached, a racing manual request, a TMDB hiccup: nothing is marked, so the entry
      # stays on the watchlist and the next tick retries it once the cause clears.
      {:error, reason} ->
        Logger.info(
          "watchlist sync: user #{user.id} could not request tmdb #{entry.tmdb_id}: " <>
            inspect(reason)
        )
    end
  end
end
