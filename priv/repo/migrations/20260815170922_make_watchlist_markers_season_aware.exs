defmodule Cinder.Repo.Migrations.MakeWatchlistMarkersSeasonAware do
  use Ecto.Migration

  def up do
    drop unique_index(:synced_watchlist_entries, [:user_id, :tmdb_id])

    alter table(:synced_watchlist_entries) do
      add :target_type, :string, null: false, default: "movie"
      # Movies use 0; TV uses its positive season number. Keeping this non-null makes SQLite's
      # unique index actually unique (NULL values would otherwise compare as distinct).
      add :season_number, :integer, null: false, default: 0
    end

    create unique_index(
             :synced_watchlist_entries,
             [:user_id, :target_type, :tmdb_id, :season_number]
           )
  end

  def down do
    drop_if_exists unique_index(
                     :synced_watchlist_entries,
                     [:user_id, :target_type, :tmdb_id, :season_number]
                   )

    # The old table cannot represent TV and movie ids in separate namespaces.
    execute("DELETE FROM synced_watchlist_entries WHERE target_type != 'movie'")

    alter table(:synced_watchlist_entries) do
      remove :target_type
      remove :season_number
    end

    create unique_index(:synced_watchlist_entries, [:user_id, :tmdb_id])
  end
end
