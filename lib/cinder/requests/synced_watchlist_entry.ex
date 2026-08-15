defmodule Cinder.Requests.SyncedWatchlistEntry do
  @moduledoc """
  A marker that one user's Plex watchlist entry has already been turned into a movie or season
  request by `Cinder.Requests.WatchlistSync`, which owns this table.

  The request row can't carry this on its own: `Catalog.delete_movie/3` deliberately reaps the
  title's `:approved` request in the same transaction (so the requester isn't stranded behind a
  stale "Approved" badge), which would make a still-watchlisted title look new to the next tick
  and silently re-request — and, for an admin or under `auto_approve_all`, re-download — what was
  just deleted. This marker outlives the reap, so a deletion sticks.

  Written only after `create_request/2` actually succeeds, so a quota-blocked or transient failure
  is still retried on the next tick.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "synced_watchlist_entries" do
    field :target_type, :string, default: "movie"
    field :tmdb_id, :integer
    field :season_number, :integer, default: 0
    belongs_to :user, Cinder.Accounts.User
    timestamps()
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:user_id, :target_type, :tmdb_id, :season_number])
    |> validate_required([:user_id, :target_type, :tmdb_id, :season_number])
    |> validate_inclusion(:target_type, ["movie", "season"])
    |> validate_number(:season_number, greater_than_or_equal_to: 0)
    |> unique_constraint([:user_id, :target_type, :tmdb_id, :season_number])
  end
end
