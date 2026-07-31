defmodule Cinder.Repo.Migrations.AddJellyfinAuthToUsers do
  use Ecto.Migration

  # Additive, for "Sign in with Jellyfin", mirroring add_plex_auth_to_users: jellyfin_user_id
  # links a user to their Jellyfin account (nullable — most users still authenticate by
  # password; Jellyfin ids are opaque GUID strings, not integers like Plex's), jellyfin_username
  # is display-only, refreshed on every Jellyfin login.
  def change do
    alter table(:users) do
      add :jellyfin_user_id, :string
      add :jellyfin_username, :string
    end

    create unique_index(:users, [:jellyfin_user_id], where: "jellyfin_user_id IS NOT NULL")
  end
end
