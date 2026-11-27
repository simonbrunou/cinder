defmodule Cinder.Repo.Migrations.CreateNativeIndexerCaptchas do
  use Ecto.Migration

  # A Cardigann configured indexer's captcha session (#1681): runtime state that only
  # `Cinder.Acquisition.IndexerSource.Native` writes, one row per configured indexer, gone with
  # the indexer. The landing page's cookies and form are one ciphertext whose plaintext names its
  # scope and the indexer id.
  def change do
    create table(:native_indexer_captchas, primary_key: false) do
      add :configured_indexer_id,
          references(:configured_indexers, on_delete: :delete_all),
          primary_key: true

      add :ciphertext, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end
  end
end
