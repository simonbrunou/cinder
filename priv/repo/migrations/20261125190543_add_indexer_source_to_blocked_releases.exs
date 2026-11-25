defmodule Cinder.Repo.Migrations.AddIndexerSourceToBlockedReleases do
  use Ecto.Migration

  # #1645: an indexer id names a site only beside its source, since Prowlarr's indexer 3 and a
  # native indexer 3 are different sites. A row sets `indexer_source` exactly when it sets
  # `indexer_id`. Prowlarr was the one source before this migration, so every row that holds an
  # indexer id gets `'prowlarr'`, and a row with none keeps a null source.
  def up do
    alter table(:blocked_releases) do
      add :indexer_source, :string
    end

    execute(
      "UPDATE blocked_releases SET indexer_source = 'prowlarr' WHERE indexer_id IS NOT NULL"
    )
  end

  def down do
    alter table(:blocked_releases) do
      remove :indexer_source
    end
  end
end
