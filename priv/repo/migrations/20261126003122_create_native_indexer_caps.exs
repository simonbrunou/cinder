defmodule Cinder.Repo.Migrations.CreateNativeIndexerCaps do
  use Ecto.Migration

  # A Newznab or Torznab configured indexer's parsed `t=caps` answer (#1652): runtime state that
  # only `Cinder.Acquisition.IndexerSource.Native` writes, one row per configured indexer, gone
  # with the indexer.
  def change do
    create table(:native_indexer_caps, primary_key: false) do
      add :configured_indexer_id,
          references(:configured_indexers, on_delete: :delete_all),
          primary_key: true

      # The configured indexer's `config_version` when the caps were fetched: a row under another
      # version is not used.
      add :config_version, :integer, null: false
      add :caps, :map, null: false
      add :fetched_at, :utc_datetime_usec, null: false
    end
  end
end
