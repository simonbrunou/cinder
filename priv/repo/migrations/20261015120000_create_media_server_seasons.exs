defmodule Cinder.Repo.Migrations.CreateMediaServerSeasons do
  use Ecto.Migration

  # The media server's own TV season inventory, keyed by the show's TMDB id rather than a Cinder
  # series: a season that is already on Plex/Jellyfin reads as available on the request page even
  # for a show Cinder never added. The reconciler replaces the whole set on each complete read.
  def change do
    create table(:media_server_seasons) do
      add :tmdb_id, :integer, null: false
      add :season_number, :integer, null: false
      add :episode_count, :integer, null: false
      add :item_id, :string, null: false
    end

    create unique_index(:media_server_seasons, [:tmdb_id, :season_number])
  end
end
