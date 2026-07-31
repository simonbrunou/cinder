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

  Only `movie` entries sync. Cinder requests TV per season and a watchlisted show names no
  season, so there is nothing unambiguous to create from one — shows are skipped.

  Dedupe is a per-user `synced_watchlist_entries` marker (this module owns that table), unioned
  with the user's existing movie request rows so a title they already asked for manually isn't
  asked for twice. A request row alone would not be enough: `Catalog.delete_movie/3` reaps the
  title's `:approved` request in the same transaction, so a deleted-but-still-watchlisted movie
  would look new to the next tick and be silently re-requested (and, for an admin or under
  `auto_approve_all`, re-downloaded). The marker outlives that reap, so a deletion sticks.
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
  alias Cinder.Repo
  alias Cinder.Requests
  alias Cinder.Requests.SyncedWatchlistEntry

  @default_interval :timer.minutes(15)
  use Cinder.Download.PollerSkeleton, log_prefix: "watchlist sync", stateful: false

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

  defp request_new(user, entries) do
    seen = already_seen(user)

    for %{type: "movie", tmdb_id: tmdb_id} = entry <- entries,
        not MapSet.member?(seen, tmdb_id) do
      request_one(user, entry)
    end

    :ok
  end

  # The durable markers, plus the movie requests this user already has by any route — the latter
  # so a title they asked for manually before opting in isn't asked for a second time.
  defp already_seen(user) do
    user
    |> Requests.list_for_user()
    |> Enum.filter(&(&1.target_type == "movie"))
    |> MapSet.new(& &1.target_id)
    |> MapSet.union(synced_tmdb_ids(user))
  end

  defp synced_tmdb_ids(user) do
    from(e in SyncedWatchlistEntry, where: e.user_id == ^user.id, select: e.tmdb_id)
    |> Repo.all()
    |> MapSet.new()
  end

  # Idempotent by the unique index: two ticks racing the same entry leave one marker, and a
  # marker that somehow fails to write only costs a retry next tick, never a crash.
  defp mark_synced(user, tmdb_id) do
    %SyncedWatchlistEntry{}
    |> SyncedWatchlistEntry.changeset(%{user_id: user.id, tmdb_id: tmdb_id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :tmdb_id])
    |> case do
      {:ok, _entry} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "watchlist sync: user #{user.id} tmdb #{tmdb_id} requested but not marked: " <>
            inspect(reason)
        )
    end
  end

  defp request_one(user, entry) do
    attrs = %{
      target_type: "movie",
      target_id: entry.tmdb_id,
      title: entry.title,
      year: entry.year
    }

    case Requests.create_request(user, attrs) do
      {:ok, _request} ->
        mark_synced(user, entry.tmdb_id)

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
