defmodule Cinder.Repo.Migrations.AddPlexWatchlistSyncToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      # Base64 of the Cloak (Cinder.Vault) ciphertext, exactly like a secret settings row —
      # never the plaintext plex.tv auth token.
      add :plex_token, :string
      add :plex_watchlist_sync, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:users) do
      remove :plex_token
      remove :plex_watchlist_sync
    end
  end
end
