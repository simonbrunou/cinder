defmodule Cinder.Repo.Migrations.AddPlexAuthToUsers do
  use Ecto.Migration

  # Additive, for "Sign in with Plex": plex_id links a user to their Plex account
  # (nullable — most users still authenticate by password); plex_username is
  # display-only, refreshed on every Plex login.
  def change do
    alter table(:users) do
      add :plex_id, :integer
      add :plex_username, :string
    end

    create unique_index(:users, [:plex_id], where: "plex_id IS NOT NULL")
  end
end
