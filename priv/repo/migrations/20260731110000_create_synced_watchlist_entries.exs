defmodule Cinder.Repo.Migrations.CreateSyncedWatchlistEntries do
  use Ecto.Migration

  def change do
    # "This user's watchlist entry has already been turned into a request" — the durable dedupe
    # for Cinder.Requests.WatchlistSync. A request row alone can't carry this: deleting a movie
    # reaps its :approved request (Catalog.delete_movie/3 -> reap_approved_for_target/2), which
    # would make a still-watchlisted title look new again and silently re-download it.
    create table(:synced_watchlist_entries) do
      # Mirrors requests' GDPR handling: a user deletion cascades away their sync markers.
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :tmdb_id, :integer, null: false
      timestamps()
    end

    # Also the conflict target for the idempotent per-tick upsert.
    create unique_index(:synced_watchlist_entries, [:user_id, :tmdb_id])
  end
end
