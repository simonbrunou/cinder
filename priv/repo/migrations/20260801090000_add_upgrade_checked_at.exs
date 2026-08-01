defmodule Cinder.Repo.Migrations.AddUpgradeCheckedAt do
  use Ecto.Migration

  # The rotation clock for `Cinder.Catalog.UpgradeHunter`: each pass takes the N least-recently
  # checked library items, so a large library is swept without hammering the indexer. NULL means
  # "never checked" and sorts first, so everything already in the library is picked up.
  def change do
    alter table(:movies) do
      add :upgrade_checked_at, :utc_datetime
    end

    alter table(:episodes) do
      add :upgrade_checked_at, :utc_datetime
    end
  end
end
