defmodule Cinder.Repo.Migrations.CreateNativeIndexerClearances do
  use Ecto.Migration

  # A Cardigann configured indexer's FlareSolverr clearance (#1682): runtime state that only
  # `Cinder.Acquisition.IndexerSource.Native` writes, one row per configured indexer, gone with
  # the indexer. The cookies and the user agent are one ciphertext whose plaintext names its
  # scope and the indexer id.
  def change do
    create table(:native_indexer_clearances, primary_key: false) do
      add :configured_indexer_id,
          references(:configured_indexers, on_delete: :delete_all),
          primary_key: true

      add :ciphertext, :text, null: false
      # The configured indexer's `config_version` the solve ran under.
      add :config_version, :integer, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end
  end
end
