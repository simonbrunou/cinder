defmodule Cinder.Repo.Migrations.AddIndexerIdToBlockedReleases do
  use Ecto.Migration

  # #1515: the block row Cinder tries to write for a TV release refused at submission records the
  # indexer id of the refused search result, when the download intent stored one, and then
  # matches its title only in a result from that indexer or from no known indexer. Nil means the
  # row matches its title from every indexer; every row stored before this migration keeps nil.
  def change do
    alter table(:blocked_releases) do
      add :indexer_id, :integer
    end
  end
end
