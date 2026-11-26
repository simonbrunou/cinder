defmodule Cinder.Repo.Migrations.CreateNativeIndexerStatus do
  use Ecto.Migration

  # A configured indexer's backoff state (#1654): runtime state that only
  # `Cinder.Acquisition.IndexerSource.Native` writes, one row per configured indexer, gone with
  # the indexer. Every column holds a closed tag, a count or a time, never a URL, header or body.
  def change do
    create table(:native_indexer_status, primary_key: false) do
      add :configured_indexer_id,
          references(:configured_indexers, on_delete: :delete_all),
          primary_key: true

      # The configured indexer's `config_version` the row was written under.
      add :config_version, :integer, null: false
      add :backoff, :string, null: false
      add :level, :integer, null: false
      add :backoff_until, :utc_datetime
      add :failures_in_row, :integer, null: false
      add :last_failure, :string
      add :last_failure_code, :integer
      add :last_failure_at, :utc_datetime
      add :credentials_rejected, :boolean, null: false
      add :credentials_rejected_by, :string
      add :credentials_rejected_code, :integer
      add :last_success_at, :utc_datetime
    end
  end
end
