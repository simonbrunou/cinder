defmodule Cinder.Repo.Migrations.CreateNativeIndexerCookies do
  use Ecto.Migration

  # A Cardigann configured indexer's login cookies (#1680): runtime state that only
  # `Cinder.Acquisition.IndexerSource.Native` writes, one row per configured indexer, gone with
  # the indexer. The jar is one ciphertext whose plaintext names its scope and the indexer id.
  def change do
    create table(:native_indexer_cookies, primary_key: false) do
      add :configured_indexer_id,
          references(:configured_indexers, on_delete: :delete_all),
          primary_key: true

      add :ciphertext, :text, null: false
      # The configured indexer's `credentials_version` the login ran under.
      add :credentials_version, :integer, null: false
      add :logged_in_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end
  end
end
