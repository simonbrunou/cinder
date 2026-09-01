defmodule Cinder.Repo.Migrations.CreateBookBlockedReleases do
  use Ecto.Migration

  def change do
    # The books sibling of `blocked_releases` (`Cinder.Catalog.BlockedRelease`): a release title
    # proven bad for one target, so a manual Retry or "Find a better match" search does not
    # re-offer it. No unique constraint — mirrors `blocked_releases`, which has none either; a
    # repeat block of the same title is harmless.
    create table(:book_blocked_releases) do
      add :book_target_id, references(:book_targets, on_delete: :delete_all), null: false
      add :release_title, :string, null: false
      add :reason, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:book_blocked_releases, [:book_target_id])
  end
end
